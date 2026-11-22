///|
/// Max request body size accepted for buffering (64 MiB).
let max_body_size : Int32 = 64 * 1024 * 1024

///|
pub(all) suberror ProxyError {
  ProxyError(String)
}

///|
/// Handle one client connection: read one HTTP request, optionally rewrite
/// the Chat Completions system message, forward it to the upstream and
/// stream the response back (SSE works). The connection is closed
/// afterwards (`Connection: close`). Every proxied request is recorded
/// in the flow store for the monitor UI.
pub async fn handle_connection(
  client : @socket.Tcp,
  cfg : @config.Config,
  store : @monitor.FlowStore,
  client_addr : String,
) -> Unit {
  handle_connection_inner(client, cfg, store, client_addr) catch {
    e => println("[proxy] connection error: " + e.to_string())
  }
}

///|
async fn handle_connection_inner(
  client : @socket.Tcp,
  cfg : @config.Config,
  store : @monitor.FlowStore,
  client_addr : String,
) -> Unit {
  let line = match client.read_until("\r\n") {
    Some(l) if !l.is_empty() => l
    _ => return // client closed without sending anything
  }
  let (http_method, target, _version) = match
    @httpparse.parse_request_line(line) {
    Some(parts) => parts
    None => {
      send_simple(client, 400, "Bad Request")
      return
    }
  }
  if http_method == "CONNECT" {
    send_simple(client, 405, "Method Not Allowed")
    return
  }
  let headers : Array[(String, String)] = []
  for ;; {
    match client.read_until("\r\n") {
      Some("") => break
      Some(l) =>
        match @httpparse.parse_header_line(l) {
          Some(h) => headers.push(h)
          None => ()
        }
      None => return // EOF in the middle of headers
    }
  }
  let head : @httpparse.RequestHead = { http_method, target, headers, }
  if @httpparse.header_value(head, "upgrade") is Some(_) {
    send_simple(client, 501, "Not Implemented")
    return
  }
  if @httpparse.header_value(head, "expect") is Some(v) &&
    v.clamped_view().to_lower().contains("100-continue") {
    client.write("HTTP/1.1 100 Continue\r\n\r\n")
  }
  let body = read_request_body(client, head)
  let intercepted = @httpparse.is_chat_completions(http_method, target)
  let upstream_addr = cfg.upstream_host + ":" + cfg.upstream_port.to_string()
  let flow = store.begin(
    client_addr~,
    http_method~,
    target~,
    request_headers=headers,
    request_body=body,
    intercepted~,
    upstream=upstream_addr,
  )
  // Finalize the flow even if the connection aborts mid-way. Persisting to
  // disk is protected from cancellation so an aborted client does not lose
  // the record.
  errdefer (if !flow.finished {
    if flow.error is None {
      flow.error = Some("connection aborted")
    }
    @async.protect_from_cancel(() => store.finish(flow))
  })
  let mut out_body = body
  if intercepted {
    if body.length() > 0 {
      try {
        let json = @json.parse(@utf8.decode(body))
        if ensure_system_prefix_with(json, cfg.system_prompt) {
          out_body = @utf8.encode(json.stringify())
          flow.injected = true
          let (capped, truncated) = @monitor.cap_bytes(out_body)
          flow.upstream_body = Some(capped)
          flow.upstream_truncated = truncated
          println(
            "[proxy] " +
            http_method +
            " " +
            target +
            " -> injected system prefix",
          )
        } else {
          println(
            "[proxy] " +
            http_method +
            " " +
            target +
            " -> system prefix ok, pass through",
          )
        }
      } catch {
        e =>
          println(
            "[proxy] warning: cannot parse body as JSON, forwarding unchanged (" +
            e.to_string() +
            ")",
          )
      }
    } else {
      println(
        "[proxy] " + http_method + " " + target + " -> empty body, pass through",
      )
    }
  }
  let upstream = @socket.Tcp::connect_to_host(
    cfg.upstream_host,
    port=cfg.upstream_port,
  ) catch {
    e => {
      println("[proxy] upstream connect failed: " + e.to_string())
      flow.error = Some("upstream connect failed: " + e.to_string())
      flow.status = 502
      flow.reason = "Bad Gateway"
      flow.response_body = @utf8.encode("proxy error: Bad Gateway\n")
      flow.response_size = flow.response_body.length()
      send_simple(client, 502, "Bad Gateway")
      store.finish(flow)
      return
    }
  }
  defer upstream.close()
  let send_cl = out_body.length() > 0 ||
    http_method == "POST" ||
    http_method == "PUT" ||
    http_method == "PATCH"
  let out_head = @httpparse.build_upstream_head(
    head,
    cfg.upstream_host,
    cfg.upstream_port,
    out_body.length(),
    send_cl,
  )
  upstream.write(out_head)
  if out_body.length() > 0 {
    upstream.write(out_body)
  }
  // Read the response head for the monitor, forward it verbatim to the
  // client, then stream the body back as it arrives (SSE / chunked),
  // capturing a capped copy for the monitor.
  let status_line = match upstream.read_until("\r\n") {
    Some(l) => l
    None => {
      flow.error = Some("upstream closed without response")
      store.finish(flow)
      return
    }
  }
  match @httpparse.parse_status_line(status_line) {
    Some((code, reason)) => {
      flow.status = code
      flow.reason = reason
    }
    None => flow.error = Some("bad status line: " + status_line)
  }
  let resp_headers : Array[(String, String)] = []
  let mut head_raw = status_line + "\r\n"
  for ;; {
    match upstream.read_until("\r\n") {
      Some("") => {
        head_raw = head_raw + "\r\n"
        break
      }
      Some(l) => {
        head_raw = head_raw + l + "\r\n"
        match @httpparse.parse_header_line(l) {
          Some(h) => resp_headers.push(h)
          None => ()
        }
      }
      None => break
    }
  }
  flow.response_headers = resp_headers
  client.write(head_raw)
  let resp_chunked = match find_header(resp_headers, "transfer-encoding") {
    Some(v) => v.clamped_view().to_lower().contains("chunked")
    None => false
  }
  let buf = @buffer.Buffer()
  let mut resp_size = 0
  for ;; {
    match upstream.read_some(max_len=65536) {
      Some(chunk) => {
        client.write(chunk)
        resp_size += chunk.length()
        if buf.length() < @monitor.body_capture_limit {
          let room = @monitor.body_capture_limit - buf.length()
          let take = if chunk.length() < room { chunk.length() } else { room }
          buf.write_bytes(chunk.clamped_view(end=take))
        }
      }
      None => break
    }
  }
  let raw = buf.to_bytes()
  flow.response_body = if resp_chunked {
    @monitor.decode_chunked_body(raw)
  } else {
    raw
  }
  flow.response_size = resp_size
  flow.response_truncated = resp_size > @monitor.body_capture_limit
  store.finish(flow)
}

///|
fn find_header(headers : Array[(String, String)], name : String) -> String? {
  for pair in headers {
    if pair.0.clamped_view().equal_ignore_ascii_case(name) {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Read the request body, supporting both `Content-Length` and
/// `Transfer-Encoding: chunked`.
async fn read_request_body(
  client : @socket.Tcp,
  head : @httpparse.RequestHead,
) -> Bytes {
  let chunked = match @httpparse.header_value(head, "transfer-encoding") {
    Some(v) => v.clamped_view().to_lower().contains("chunked")
    None => false
  }
  if chunked {
    let buf = @buffer.Buffer()
    for ;; {
      let size_line = match client.read_until("\r\n") {
        Some(l) => l
        None => raise ProxyError("EOF in chunked body")
      }
      let size_view = match size_line.clamped_view().split_once(";") {
        Some((s, _)) => s
        None => size_line.clamped_view()
      }
      let size = @string.parse_int(size_view.trim(), radix=16) catch {
        _ => raise ProxyError("bad chunk size: " + size_line)
      }
      if size < 0 || buf.length() + size > max_body_size {
        raise ProxyError("chunked body too large")
      }
      if size == 0 {
        // Consume trailers until the terminating empty line.
        for ;; {
          match client.read_until("\r\n") {
            Some("") | None => break
            _ => ()
          }
        }
        break
      }
      buf.write_bytes(client.read_exactly(size))
      let _ = client.read_exactly(2) // CRLF after each chunk
    }
    return buf.to_bytes()
  }
  match @httpparse.header_value(head, "content-length") {
    Some(v) => {
      let n = @string.parse_int(v.clamped_view().trim()) catch {
        _ => raise ProxyError("bad Content-Length: " + v)
      }
      if n < 0 || n > max_body_size {
        raise ProxyError("body too large or invalid Content-Length")
      }
      if n == 0 {
        @utf8.encode("")
      } else {
        client.read_exactly(n)
      }
    }
    None => @utf8.encode("")
  }
}

///|
async fn send_simple(
  client : @socket.Tcp,
  code : Int32,
  reason : String,
) -> Unit {
  let body = "proxy error: " + reason + "\n"
  let head = "HTTP/1.1 " +
    code.to_string() +
    " " +
    reason +
    "\r\n" +
    "Content-Type: text/plain; charset=utf-8\r\n" +
    "Content-Length: " +
    body.length().to_string() +
    "\r\n" +
    "Connection: close\r\n\r\n"
  client.write(head)
  client.write(body)
}
