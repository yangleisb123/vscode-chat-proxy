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
/// afterwards (`Connection: close`).
pub async fn handle_connection(client : @socket.Tcp, cfg : Config) -> Unit {
  handle_connection_inner(client, cfg) catch {
    e => println("[proxy] connection error: " + e.to_string())
  }
}

///|
async fn handle_connection_inner(client : @socket.Tcp, cfg : Config) -> Unit {
  let line = match client.read_until("\r\n") {
    Some(l) if !l.is_empty() => l
    _ => return // client closed without sending anything
  }
  let (http_method, target, _version) = match parse_request_line(line) {
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
        match parse_header_line(l) {
          Some(h) => headers.push(h)
          None => ()
        }
      None => return // EOF in the middle of headers
    }
  }
  let head : RequestHead = { http_method, target, headers, }
  if header_value(head, "upgrade") is Some(_) {
    send_simple(client, 501, "Not Implemented")
    return
  }
  if header_value(head, "expect") is Some(v) &&
    v.clamped_view().to_lower().contains("100-continue") {
    client.write("HTTP/1.1 100 Continue\r\n\r\n")
  }
  let body = read_request_body(client, head)
  let mut out_body = body
  if is_chat_completions(http_method, target) {
    if body.length() > 0 {
      try {
        let json = @json.parse(@utf8.decode(body))
        if ensure_system_prefix(json) {
          out_body = @utf8.encode(json.stringify())
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
      send_simple(client, 502, "Bad Gateway")
      return
    }
  }
  defer upstream.close()
  let send_cl = out_body.length() > 0 ||
    http_method == "POST" ||
    http_method == "PUT" ||
    http_method == "PATCH"
  let out_head = build_upstream_head(
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
  // Stream the response back as it arrives (works for SSE / chunked).
  // Upstream was told `Connection: close`, so EOF marks the end.
  for ;; {
    match upstream.read_some(max_len=65536) {
      Some(chunk) => client.write(chunk)
      None => break
    }
  }
}

///|
/// Read the request body, supporting both `Content-Length` and
/// `Transfer-Encoding: chunked`.
async fn read_request_body(client : @socket.Tcp, head : RequestHead) -> Bytes {
  let chunked = match header_value(head, "transfer-encoding") {
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
  match header_value(head, "content-length") {
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
