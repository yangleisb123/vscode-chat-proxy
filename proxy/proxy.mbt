///|
/// Max request body size accepted for buffering (64 MiB).
let max_body_size : Int32 = 64 * 1024 * 1024

///|
/// Max idle upstream connections kept per (host,port) for reuse.
let pool_max_idle : Int32 = 32

///|
/// Idle upstream connection pool (single-threaded event loop, no lock needed).
let upstream_pool : Map[String, Array[@socket.Tcp]] = Map([])

///|
/// Capped copy of a response body for the monitor, plus total byte count.
priv struct BodyCapture {
  buf : @buffer.Buffer
  mut size : Int32
}

///|
fn BodyCapture::add(self : BodyCapture, chunk : Bytes) -> Unit {
  self.size += chunk.length()
  if self.buf.length() < @monitor.body_capture_limit {
    let room = @monitor.body_capture_limit - self.buf.length()
    let take = if chunk.length() < room { chunk.length() } else { room }
    self.buf.write_bytes(chunk.clamped_view(end=take))
  }
}

///|
pub(all) suberror ProxyError {
  ProxyError(String)
}

///|
/// Handle one client connection: serve requests in a keep-alive loop, rewriting
/// the Chat Completions system message on the way and reusing pooled upstream
/// connections. SSE / chunked responses are streamed chunk-by-chunk. Every
/// request is recorded in the flow store for the monitor UI.
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
fn pool_key(host : String, port : Int32) -> String {
  host + ":" + port.to_string()
}

///|
/// Take an upstream connection: reuse an idle pooled one when available,
/// otherwise dial. Returns (conn, from_pool) so callers can retry once on a
/// stale pooled socket.
async fn take_upstream(host : String, port : Int32) -> (@socket.Tcp, Bool) {
  let key = pool_key(host, port)
  match upstream_pool.get(key) {
    Some(arr) =>
      match arr.pop() {
        Some(conn) => (conn, true)
        None => (@socket.Tcp::connect_to_host(host, port~), false)
      }
    None => (@socket.Tcp::connect_to_host(host, port~), false)
  }
}

///|
fn return_upstream(host : String, port : Int32, conn : @socket.Tcp) -> Unit {
  let key = pool_key(host, port)
  let arr = upstream_pool.get_or_init(key, () => [])
  if arr.length() < pool_max_idle {
    arr.push(conn)
  } else {
    conn.close()
  }
}

///|
async fn handle_connection_inner(
  client : @socket.Tcp,
  cfg : @config.Config,
  store : @monitor.FlowStore,
  client_addr : String,
) -> Unit {
  // Keep-alive loop: serve multiple requests per client connection.
  for ;; {
    let line = match client.read_until("\r\n") {
      Some(l) => l
      None => return // client closed
    }
    if line.is_empty() {
      continue
    }
    let (http_method, target, version) = match
      @httpparse.parse_request_line(line) {
      Some(parts) => parts
      None => {
        send_simple(client, 400, "Bad Request")
        return
      }
    }
    if http_method == "CONNECT" {
      handle_connect(client, target, store, client_addr)
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
        None => return
      }
    }
    let conn_hdr = match
      @httpparse.header_value({ http_method, target, headers, }, "connection") {
      Some(v) => v.clamped_view().to_lower()
      None => ""
    }
    let client_keep = if version == "HTTP/1.0" {
      conn_hdr.contains("keep-alive")
    } else {
      !conn_hdr.contains("close")
    }
    // Destination: forward mode derives it from the request itself; reverse
    // mode keeps the pinned upstream.
    let (up_host, up_port, out_target) = if cfg.forward {
      if target.clamped_view().has_prefix("http://") {
        match @httpparse.absolute_http_target(target) {
          Some((h, p, path)) => (h, p, path)
          None => {
            send_simple(client, 400, "Bad Request")
            return
          }
        }
      } else if target.clamped_view().has_prefix("https://") {
        send_simple(client, 501, "HTTPS MITM Not Supported")
        return
      } else {
        match
          @httpparse.header_value({ http_method, target, headers, }, "host") {
          Some(hv) =>
            match @httpparse.parse_authority(hv, 80) {
              Some((h, p)) => (h, p, target)
              None => {
                send_simple(client, 400, "Bad Host Header")
                return
              }
            }
          None => {
            send_simple(client, 400, "Missing Host Header")
            return
          }
        }
      }
    } else {
      (cfg.upstream_host, cfg.upstream_port, target)
    }
    let head : @httpparse.RequestHead = {
      http_method,
      target: out_target,
      headers,
    }
    if @httpparse.header_value(head, "upgrade") is Some(_) {
      send_simple(client, 501, "Not Implemented")
      return
    }
    if @httpparse.header_value(head, "expect") is Some(v) &&
      v.clamped_view().to_lower().contains("100-continue") {
      client.write("HTTP/1.1 100 Continue\r\n\r\n")
    }
    let body = read_request_body(client, head)
    let intercepted = store.intercept_enabled() &&
      @httpparse.is_chat_completions(http_method, out_target)
    let flow = store.begin(
      client_addr~,
      http_method~,
      target~,
      request_headers=headers,
      request_body=body,
      intercepted~,
      upstream=pool_key(up_host, up_port),
    )
    let mut out_body = body
    if intercepted && body.length() > 0 {
      try {
        let json = @json.parse(@utf8.decode(body))
        if ensure_system_prefix_with(json, cfg.system_prompt) {
          out_body = @utf8.encode(json.stringify())
          flow.injected = true
          let (capped, truncated) = @monitor.cap_bytes(out_body)
          flow.upstream_body = Some(capped)
          flow.upstream_truncated = truncated
        }
      } catch {
        e =>
          println(
            "[proxy] warning: cannot parse body as JSON, forwarding unchanged (" +
            e.to_string() +
            ")",
          )
      }
    }
    let send_cl = out_body.length() > 0 ||
      http_method == "POST" ||
      http_method == "PUT" ||
      http_method == "PATCH"
    let out_head = @httpparse.build_upstream_head_keepalive(
      head,
      up_host,
      up_port,
      out_body.length(),
      send_cl,
    )
    // Send request and read the response status line, retrying once on a stale
    // pooled connection.
    let (conn, status_line) = match
      send_and_read_head(up_host, up_port, out_head, out_body) {
      Ok(pair) => pair
      Err(msg) => {
        flow.error = Some(msg)
        flow.status = 502
        flow.reason = "Bad Gateway"
        send_simple(client, 502, "Bad Gateway")
        store.finish(flow)
        return
      }
    }
    let framed = forward_response(client, conn, flow, status_line, client_keep) catch {
      e => {
        conn.close()
        flow.error = Some("response aborted: " + e.to_string())
        store.finish(flow)
        return
      }
    }
    store.finish(flow)
    if framed.1 {
      return_upstream(up_host, up_port, conn)
    } else {
      conn.close()
    }
    if !(client_keep && framed.0) {
      return // close-delimited or client asked to close
    }
  }
}

///|
/// Send the request head+body on a (possibly pooled) upstream connection and
/// read the response status line. A stale pooled socket is discarded and the
/// request retried once on a fresh connection.
async fn send_and_read_head(
  host : String,
  port : Int32,
  out_head : String,
  out_body : Bytes,
) -> Result[(@socket.Tcp, String), String] {
  let taken = take_upstream(host, port) catch {
    e => return Err("upstream connect failed: " + e.to_string())
  }
  let mut conn = taken.0
  let mut from_pool = taken.1
  for attempt in [0, 1] {
    let wrote = try {
      conn.write(out_head)
      if out_body.length() > 0 {
        conn.write(out_body)
      }
      true
    } catch {
      _ => false
    }
    let status = if wrote {
      conn.read_until("\r\n") catch {
        _ => None
      }
    } else {
      None
    }
    match status {
      Some(l) if !l.is_empty() => return Ok((conn, l))
      _ => {
        conn.close()
        if attempt == 0 && from_pool {
          from_pool = false
          conn = @socket.Tcp::connect_to_host(host, port~) catch {
            e => return Err("upstream connect failed: " + e.to_string())
          }
          continue
        }
        return Err("upstream closed without response")
      }
    }
  }
  Err("upstream closed without response")
}

///|
/// Forward the response head (rewriting Connection) and stream the body with
/// correct framing so the upstream connection can be reused. Returns
/// (framed, upstream_reusable).
async fn forward_response(
  client : @socket.Tcp,
  conn : @socket.Tcp,
  flow : @monitor.Flow,
  status_line : String,
  client_keep : Bool,
) -> (Bool, Bool) {
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
    match conn.read_until("\r\n") {
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
  let resp_conn = match find_header(resp_headers, "connection") {
    Some(v) => v.clamped_view().to_lower()
    None => ""
  }
  let cl = match find_header(resp_headers, "content-length") {
    Some(v) =>
      Some(@string.parse_int(v.clamped_view().trim()) catch { _ => -1 })
    None => None
  }
  let chunked = match find_header(resp_headers, "transfer-encoding") {
    Some(v) => v.clamped_view().to_lower().contains("chunked")
    None => false
  }
  let framed = chunked || (cl is Some(n) && n >= 0)
  let upstream_keep = framed &&
    !resp_conn.contains("close") &&
    (
      status_line.clamped_view().has_prefix("HTTP/1.1") ||
      resp_conn.contains("keep-alive")
    )
  // Rewrite Connection to match what the client connection will do.
  let mut out_head = status_line + "\r\n"
  for pair in resp_headers {
    if pair.0.clamped_view().equal_ignore_ascii_case("connection") {
      continue
    }
    out_head = out_head + pair.0 + ": " + pair.1 + "\r\n"
  }
  out_head = out_head +
    "Connection: " +
    (if framed && client_keep { "keep-alive" } else { "close" }) +
    "\r\n\r\n"
  client.write(out_head)
  let cap : BodyCapture = { buf: @buffer.Buffer(), size: 0, }
  if chunked {
    for ;; {
      let size_line = match conn.read_until("\r\n") {
        Some(l) => l
        None => break
      }
      client.write(size_line + "\r\n")
      cap.add(@utf8.encode(size_line + "\r\n"))
      let size_view = match size_line.clamped_view().split_once(";") {
        Some((s, _)) => s
        None => size_line.clamped_view()
      }
      let size = @string.parse_int(size_view.trim(), radix=16) catch { _ => 0 }
      if size == 0 {
        for ;; {
          match conn.read_until("\r\n") {
            Some("") => {
              // The empty line after the last chunk (and any trailers)
              // terminates the chunked message: relay it too, or keep-alive
              // clients wait forever for the end of the body.
              client.write("\r\n")
              cap.add(@utf8.encode("\r\n"))
              break
            }
            None => break
            Some(t) => {
              client.write(t + "\r\n")
              cap.add(@utf8.encode(t + "\r\n"))
            }
          }
        }
        break
      }
      let data = conn.read_exactly(size)
      client.write(data)
      cap.add(data)
      let crlf = conn.read_exactly(2)
      client.write(crlf)
      cap.add(crlf)
    }
  } else if cl is Some(n) && n >= 0 {
    let mut remaining = n
    while remaining > 0 {
      let want = if remaining < 65536 { remaining } else { 65536 }
      match conn.read_some(max_len=want) {
        Some(chunk) => {
          client.write(chunk)
          cap.add(chunk)
          remaining -= chunk.length()
        }
        None => break
      }
    }
  } else {
    for ;; {
      match conn.read_some(max_len=65536) {
        Some(chunk) => {
          client.write(chunk)
          cap.add(chunk)
        }
        None => break
      }
    }
  }
  let raw = cap.buf.to_bytes()
  flow.response_body = if chunked {
    @monitor.decode_chunked_body(raw)
  } else {
    raw
  }
  flow.response_size = cap.size
  flow.response_truncated = cap.size > @monitor.body_capture_limit
  (framed, upstream_keep)
}

///|
/// Byte counters for a blind CONNECT tunnel (client->upstream / reverse).
priv struct TunnelStats {
  mut up : Int32
  mut down : Int32
}

///|
/// Task handles so whichever pump ends first can cancel the other (a blocked
/// read is not guaranteed to wake when the socket is closed).
priv struct TunnelCtl {
  mut up_task : @async.Task[Unit]?
  mut down_task : @async.Task[Unit]?
}

///|
/// CONNECT: establish a blind TCP tunnel to the requested authority and pump
/// bytes both ways until either side closes. TLS traffic passes through
/// untouched (no MITM), so bodies are not inspectable; the monitor records
/// the connection and its byte counts.
async fn handle_connect(
  client : @socket.Tcp,
  target : String,
  store : @monitor.FlowStore,
  client_addr : String,
) -> Unit {
  let (host, port) = match @httpparse.parse_authority(target, 443) {
    Some(pair) => pair
    None => {
      send_simple(client, 400, "Bad CONNECT Target")
      return
    }
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
      None => return
    }
  }
  let flow = store.begin(
    client_addr~,
    http_method="CONNECT",
    target~,
    request_headers=headers,
    request_body=@utf8.encode(""),
    intercepted=false,
    upstream=host + ":" + port.to_string(),
  )
  errdefer (if !flow.finished {
    if flow.error is None {
      flow.error = Some("connection aborted")
    }
    store.finish(flow)
  })
  let upstream = @socket.Tcp::connect_to_host(host, port~) catch {
    e => {
      flow.error = Some("upstream connect failed: " + e.to_string())
      flow.status = 502
      flow.reason = "Bad Gateway"
      send_simple(client, 502, "Bad Gateway")
      store.finish(flow)
      return
    }
  }
  defer upstream.close()
  client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
  flow.status = 200
  flow.reason = "Connection Established"
  let stats : TunnelStats = { up: 0, down: 0, }
  let ctl : TunnelCtl = { up_task: None, down_task: None, }
  @async.with_task_group() <| group => {
    let t1 = group.spawn(allow_failure=true) <| () => {
      pump(client, upstream, stats, true)
      match ctl.down_task {
        Some(t) => t.cancel()
        None => ()
      }
    }
    let t2 = group.spawn(allow_failure=true) <| () => {
      pump(upstream, client, stats, false)
      match ctl.up_task {
        Some(t) => t.cancel()
        None => ()
      }
    }
    ctl.up_task = Some(t1)
    ctl.down_task = Some(t2)
  }
  flow.request_size = stats.up
  flow.response_size = stats.down
  client.close()
  upstream.close()
  store.finish(flow)
}

///|
/// Pump one direction of a tunnel. On EOF or write error just return: the
/// wrapper cancels the sibling pump (cancellation must happen while sockets
/// are still open), and the sockets are closed once the group finishes.
async fn pump(
  src : @socket.Tcp,
  dst : @socket.Tcp,
  stats : TunnelStats,
  is_up : Bool,
) -> Unit {
  for ;; {
    match src.read_some(max_len=65536) {
      Some(chunk) => {
        if is_up {
          stats.up += chunk.length()
        } else {
          stats.down += chunk.length()
        }
        dst.write(chunk) catch {
          _ => break
        }
      }
      None => break
    }
  }
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
        for ;; {
          match client.read_until("\r\n") {
            Some("") | None => break
            _ => ()
          }
        }
        break
      }
      buf.write_bytes(client.read_exactly(size))
      let _ = client.read_exactly(2)
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
