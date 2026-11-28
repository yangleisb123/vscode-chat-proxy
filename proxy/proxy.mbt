///|
/// Max request body size accepted for buffering (64 MiB).
let max_body_size : Int32 = 64 * 1024 * 1024

///|
/// Max idle upstream connections kept per (host,port) for reuse.
let pool_max_idle : Int32 = 128

///|
/// Cap on distinct upstream hosts kept in the idle pool (bounds open FDs in
/// forward-proxy mode across arbitrary destinations).
let pool_max_hosts : Int32 = 128

///|
/// Threshold below which request/response head + body are coalesced into a
/// single `Tcp::write` syscall (cuts syscalls, TCP packets, and async yields).
let coalesce_body_limit : Int32 = 65536

///|
/// DNS resolution cache TTL (60s) for hostname upstreams.
let dns_cache_ttl_ms : UInt64 = 60_000UL

///|
let empty_bytes : Bytes = b""

///|
/// Idle upstream connection pool (single-threaded event loop, no lock needed).
let upstream_pool : Map[String, Array[@socket.Tcp]] = Map([])

///|
/// Upstream address cache: `host:port` -> `(Addr, expire_ms)`.
let dns_cache : Map[String, (@socket.Addr, UInt64)] = Map([])

///|
/// Capped copy of a response body for the monitor, plus total byte count.
priv struct BodyCapture {
  buf : @buffer.Buffer
  mut size : Int32
}

///|
fn BodyCapture::add_view(self : BodyCapture, chunk : BytesView) -> Unit {
  let clen = chunk.length()
  self.size += clen
  if self.buf.length() < @monitor.body_capture_limit {
    let room = @monitor.body_capture_limit - self.buf.length()
    let take = if clen < room { clen } else { room }
    self.buf.write_bytesview(chunk[:take])
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
fn format_addr_for_parse(host : String, port : Int32) -> String {
  if host.contains(":") {
    "[" + host + "]:" + port.to_string()
  } else {
    host + ":" + port.to_string()
  }
}

///|
/// Dial upstream with cached IP/DNS resolution so repeat connections avoid
/// worker-pool `getaddrinfo` + Happy Eyeballs task-group overhead.
async fn dial_upstream(
  host : String,
  port : Int32,
  key : String,
) -> @socket.Tcp {
  let now = @env.now()
  match dns_cache.get(key) {
    Some((addr, expire_ms)) if now < expire_ms => {
      errdefer dns_cache.remove(key)
      return @socket.Tcp::connect(addr)
    }
    _ => ()
  }
  let parsed : @socket.Addr? = Some(
    @socket.Addr::parse(format_addr_for_parse(host, port).clamped_view()),
  ) catch {
    _ => None
  }
  match parsed {
    Some(addr) => {
      if dns_cache.length() >= 256 {
        dns_cache.clear()
      }
      // Numeric IP literal: cache for 1 hour.
      dns_cache[key] = (addr, now + 3_600_000UL)
      @socket.Tcp::connect(addr)
    }
    None => {
      let addr = @socket.Addr::resolve(host, port~)
      if dns_cache.length() >= 256 {
        dns_cache.clear()
      }
      dns_cache[key] = (addr, now + dns_cache_ttl_ms)
      @socket.Tcp::connect(addr)
    }
  }
}

///|
/// Take an upstream connection: reuse an idle pooled one when available,
/// otherwise dial. Returns (conn, from_pool) so callers can retry once on a
/// stale pooled socket.
async fn take_upstream(
  host : String,
  port : Int32,
  key : String,
) -> (@socket.Tcp, Bool) {
  match upstream_pool.get(key) {
    Some(arr) =>
      match arr.pop() {
        Some(conn) => (conn, true)
        None => (dial_upstream(host, port, key), false)
      }
    None => (dial_upstream(host, port, key), false)
  }
}

///|
fn return_upstream(key : String, conn : @socket.Tcp) -> Unit {
  match upstream_pool.get(key) {
    Some(arr) =>
      if arr.length() < pool_max_idle {
        arr.push(conn)
      } else {
        conn.close()
      }
    None =>
      if upstream_pool.length() < pool_max_hosts {
        upstream_pool[key] = [conn]
      } else {
        conn.close()
      }
  }
}

///|
async fn handle_connection_inner(
  client : @socket.Tcp,
  cfg : @config.Config,
  store : @monitor.FlowStore,
  client_addr : String,
) -> Unit {
  let recording = store.is_recording()
  // Keep-alive loop: serve multiple requests per client connection.
  for ;; {
    // Read the entire HTTP request head (request line + headers) in ONE call
    // instead of one `read_until("\r\n")` allocation per header line.
    let head_block = match client.read_until("\r\n\r\n") {
      Some(b) => b
      None => return // client closed
    }
    if head_block.is_empty() {
      continue
    }
    let (http_method, target, version, headers, meta) = match
      @httpparse.parse_request_head_block(head_block) {
      Some(parts) => parts
      None => {
        send_simple(client, 400, "Bad Request")
        return
      }
    }
    if http_method == "CONNECT" {
      handle_connect(client, target, headers, store, client_addr)
      return
    }
    let client_keep = match meta.connection {
      Some(v) =>
        if version == "HTTP/1.0" {
          @httpparse.contains_ignore_ascii_case(v.clamped_view(), "keep-alive")
        } else {
          !@httpparse.contains_ignore_ascii_case(v.clamped_view(), "close")
        }
      None => version != "HTTP/1.0"
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
        match meta.host {
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
    if meta.upgrade {
      send_simple(client, 501, "Not Implemented")
      return
    }
    if meta.expect_100 {
      client.write(b"HTTP/1.1 100 Continue\r\n\r\n")
    }
    let body = read_request_body(client, meta)
    let intercepted = store.intercept_enabled() &&
      @httpparse.is_chat_completions(http_method, out_target)
    let upstream_key = pool_key(up_host, up_port)
    let flow = store.begin(
      client_addr~,
      http_method~,
      target~,
      request_headers=headers,
      request_body=body,
      intercepted~,
      upstream=upstream_key,
    )
    let mut out_body = body
    if intercepted && body.length() > 0 {
      match rewrite_chat_body_bytes(body, cfg.system_prompt) {
        Ok(Some(rewritten)) => {
          out_body = rewritten
          if recording {
            flow.injected = true
            let (capped, truncated) = @monitor.cap_bytes(out_body)
            flow.upstream_body = Some(capped)
            flow.upstream_truncated = truncated
          }
        }
        Ok(None) => ()
        Err(msg) =>
          println(
            "[proxy] warning: cannot parse body as JSON, forwarding unchanged (" +
            msg +
            ")",
          )
      }
    }
    let send_cl = out_body.length() > 0 ||
      http_method == "POST" ||
      http_method == "PUT" ||
      http_method == "PATCH"
    let head : @httpparse.RequestHead = {
      http_method,
      target: out_target,
      headers,
    }
    let combine_body = out_body.length() > 0 &&
      out_body.length() <= coalesce_body_limit
    let req_buf = @buffer.Buffer(
      capacity=512 + (if combine_body { out_body.length() } else { 0 }),
    )
    @httpparse.write_upstream_head_keepalive(
      req_buf,
      head,
      up_host,
      up_port,
      out_body.length(),
      send_cl,
    )
    if combine_body {
      req_buf.write_bytesview(out_body[:])
    }
    let req_first = req_buf.to_bytes()
    let req_rest = if combine_body { empty_bytes } else { out_body }
    // Send request and read the full response head, retrying once on a stale
    // pooled connection.
    let (conn, resp_head_block) = match
      send_and_read_head(up_host, up_port, upstream_key, req_first, req_rest) {
      Ok(pair) => pair
      Err(msg) => {
        if recording {
          flow.error = Some(msg)
          flow.status = 502
          flow.reason = "Bad Gateway"
        }
        send_simple(client, 502, "Bad Gateway")
        store.finish(flow)
        return
      }
    }
    let (status_line, resp_headers_block) = match
      resp_head_block.clamped_view().split_once("\r\n") {
      Some((sl, hdrs)) => (sl.to_owned(), hdrs)
      None => (resp_head_block, "".clamped_view())
    }
    let framed = forward_response_head_and_body(
      client, conn, flow, status_line, resp_headers_block, client_keep, http_method,
      recording,
    ) catch {
      e => {
        conn.close()
        if recording {
          flow.error = Some("response aborted: " + e.to_string())
        }
        store.finish(flow)
        return
      }
    }
    store.finish(flow)
    if framed.1 {
      return_upstream(upstream_key, conn)
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
/// read the complete response head block (status line + headers). A stale
/// pooled socket is discarded and the request retried once on a fresh socket.
async fn send_and_read_head(
  host : String,
  port : Int32,
  key : String,
  req_first : Bytes,
  req_rest : Bytes,
) -> Result[(@socket.Tcp, String), String] {
  let taken = take_upstream(host, port, key) catch {
    e => return Err("upstream connect failed: " + e.to_string())
  }
  let mut conn = taken.0
  let mut from_pool = taken.1
  for attempt = 0; attempt < 2; attempt = attempt + 1 {
    let wrote = try {
      conn.write(req_first)
      if req_rest.length() > 0 {
        conn.write(req_rest)
      }
      true
    } catch {
      _ => false
    }
    let head_block = if wrote {
      conn.read_until("\r\n\r\n") catch {
        _ => None
      }
    } else {
      None
    }
    match head_block {
      Some(b) if !b.is_empty() => return Ok((conn, b))
      _ => {
        conn.close()
        if attempt == 0 && from_pool {
          from_pool = false
          conn = dial_upstream(host, port, key) catch {
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
fn write_response_head(
  buf : @buffer.Buffer,
  status_line : String,
  resp_headers : Array[(String, String)],
  keep_client : Bool,
) -> Unit {
  buf.write_string_utf8(status_line)
  buf.write_bytesview(b"\r\n")
  for pair in resp_headers {
    let n = pair.0.clamped_view()
    if n.length() == 10 && n.equal_ignore_ascii_case("connection") {
      continue
    }
    buf.write_string_utf8(pair.0)
    buf.write_bytesview(b": ")
    buf.write_string_utf8(pair.1)
    buf.write_bytesview(b"\r\n")
  }
  if keep_client {
    buf.write_bytesview(b"Connection: keep-alive\r\n\r\n")
  } else {
    buf.write_bytesview(b"Connection: close\r\n\r\n")
  }
}

///|
async fn forward_response_head_and_body(
  client : @socket.Tcp,
  conn : @socket.Tcp,
  flow : @monitor.Flow,
  status_line : String,
  resp_headers_block : StringView,
  client_keep : Bool,
  req_method : String,
  recording : Bool,
) -> (Bool, Bool) {
  let mut status_code = 0
  match @httpparse.parse_status_line(status_line) {
    Some((code, reason)) => {
      status_code = code
      if recording {
        flow.status = code
        flow.reason = reason
      }
    }
    None =>
      if recording {
        flow.error = Some("bad status line: " + status_line)
      }
  }
  let (resp_headers, meta) = @httpparse.parse_response_headers_block(
    resp_headers_block,
  )
  if recording {
    flow.response_headers = resp_headers
  }
  let no_body = req_method == "HEAD" ||
    status_code == 204 ||
    status_code == 304 ||
    (status_code >= 100 && status_code < 200)
  let cl = meta.content_length
  let chunked = meta.chunked
  let framed = no_body || chunked || (cl is Some(n) && n >= 0)
  let resp_conn_close = match meta.connection {
    Some(v) => @httpparse.contains_ignore_ascii_case(v.clamped_view(), "close")
    None => false
  }
  let resp_conn_keep = match meta.connection {
    Some(v) =>
      @httpparse.contains_ignore_ascii_case(v.clamped_view(), "keep-alive")
    None => false
  }
  let upstream_keep = framed &&
    !resp_conn_close &&
    (status_line.clamped_view().has_prefix("HTTP/1.1") || resp_conn_keep)
  let keep_client = framed && client_keep
  if no_body {
    let head_buf = @buffer.Buffer(capacity=512)
    write_response_head(head_buf, status_line, resp_headers, keep_client)
    client.write(head_buf.to_bytes())
    return (framed, upstream_keep)
  }
  if chunked {
    let head_buf = @buffer.Buffer(capacity=512)
    write_response_head(head_buf, status_line, resp_headers, keep_client)
    client.write(head_buf.to_bytes())
    let cap : BodyCapture = { buf: @buffer.Buffer(), size: 0, }
    let chunk_buf = @buffer.Buffer(capacity=4096)
    for ;; {
      let size_line = match conn.read_until("\r\n") {
        Some(l) => l
        None => break
      }
      let size_view = match size_line.clamped_view().split_once(";") {
        Some((s, _)) => s
        None => size_line.clamped_view()
      }
      let size = @string.parse_int(size_view.trim(), radix=16) catch { _ => 0 }
      if size == 0 {
        chunk_buf.reset()
        chunk_buf.write_string_utf8(size_line)
        chunk_buf.write_bytesview(b"\r\n")
        for ;; {
          match conn.read_until("\r\n") {
            Some("") => {
              // The empty line after the last chunk (and any trailers)
              // terminates the chunked message: relay it in the same write.
              chunk_buf.write_bytesview(b"\r\n")
              break
            }
            None => break
            Some(t) => {
              chunk_buf.write_string_utf8(t)
              chunk_buf.write_bytesview(b"\r\n")
            }
          }
        }
        client.write(chunk_buf.to_bytes())
        break
      }
      let data = conn.read_exactly(size)
      let _ = conn.drop(2)
      chunk_buf.reset()
      chunk_buf.write_string_utf8(size_line)
      chunk_buf.write_bytesview(b"\r\n")
      chunk_buf.write_bytesview(data[:])
      chunk_buf.write_bytesview(b"\r\n")
      client.write(chunk_buf.to_bytes())
      if recording {
        cap.add_view(data[:])
      }
    }
    if recording {
      flow.response_body = cap.buf.to_bytes()
      flow.response_size = cap.size
      flow.response_truncated = cap.size > @monitor.body_capture_limit
    }
    return (framed, upstream_keep)
  }
  if cl is Some(n) && n >= 0 {
    if n == 0 {
      let head_buf = @buffer.Buffer(capacity=512)
      write_response_head(head_buf, status_line, resp_headers, keep_client)
      client.write(head_buf.to_bytes())
      return (framed, upstream_keep)
    }
    if n <= coalesce_body_limit {
      // Coalesce response head + small Content-Length body into ONE write
      // syscall (1 TCP packet, 1 async yield) and avoid BodyCapture copying.
      let data = conn.read_exactly(n)
      let out_buf = @buffer.Buffer(capacity=512 + n)
      write_response_head(out_buf, status_line, resp_headers, keep_client)
      out_buf.write_bytesview(data[:])
      client.write(out_buf.to_bytes())
      if recording {
        flow.response_body = data
        flow.response_size = n
        flow.response_truncated = n > @monitor.body_capture_limit
      }
      return (framed, upstream_keep)
    }
    let head_buf = @buffer.Buffer(capacity=512)
    write_response_head(head_buf, status_line, resp_headers, keep_client)
    client.write(head_buf.to_bytes())
    let cap : BodyCapture = {
      buf: @buffer.Buffer(
        capacity=if recording {
          if n < @monitor.body_capture_limit {
            n
          } else {
            @monitor.body_capture_limit
          }
        } else {
          0
        },
      ),
      size: 0,
    }
    let scratch = FixedArray::make(65536, b'\x00')
    let mut remaining = n
    while remaining > 0 {
      let want = if remaining < 65536 { remaining } else { 65536 }
      let got = conn.read(scratch, max_len=want)
      if got <= 0 {
        break
      }
      let slice = scratch.unsafe_reinterpret_as_bytes()[:got]
      client.write(slice)
      if recording {
        cap.add_view(slice)
      }
      remaining -= got
    }
    if recording {
      flow.response_body = cap.buf.to_bytes()
      flow.response_size = cap.size
      flow.response_truncated = cap.size > @monitor.body_capture_limit
    }
    return (framed, upstream_keep)
  }
  // Close-delimited response (no Content-Length and not chunked).
  let head_buf = @buffer.Buffer(capacity=512)
  write_response_head(head_buf, status_line, resp_headers, keep_client)
  client.write(head_buf.to_bytes())
  let cap : BodyCapture = { buf: @buffer.Buffer(), size: 0, }
  let scratch = FixedArray::make(65536, b'\x00')
  for ;; {
    let got = conn.read(scratch, max_len=65536)
    if got <= 0 {
      break
    }
    let slice = scratch.unsafe_reinterpret_as_bytes()[:got]
    client.write(slice)
    if recording {
      cap.add_view(slice)
    }
  }
  if recording {
    flow.response_body = cap.buf.to_bytes()
    flow.response_size = cap.size
    flow.response_truncated = cap.size > @monitor.body_capture_limit
  }
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
  headers : Array[(String, String)],
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
  let upstream_key = pool_key(host, port)
  let flow = store.begin(
    client_addr~,
    http_method="CONNECT",
    target~,
    request_headers=headers,
    request_body=empty_bytes,
    intercepted=false,
    upstream=upstream_key,
  )
  errdefer (if !flow.finished {
    if flow.error is None {
      flow.error = Some("connection aborted")
    }
    store.finish(flow)
  })
  let upstream = dial_upstream(host, port, upstream_key) catch {
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
  client.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
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
/// Pump one direction of a tunnel using a single reusable 64 KiB buffer (zero
/// per-chunk allocation). On EOF or write error just return: the wrapper
/// cancels the sibling pump while sockets are still open.
async fn pump(
  src : @socket.Tcp,
  dst : @socket.Tcp,
  stats : TunnelStats,
  is_up : Bool,
) -> Unit {
  let scratch = FixedArray::make(65536, b'\x00')
  for ;; {
    let got = src.read(scratch, max_len=65536)
    if got <= 0 {
      break
    }
    if is_up {
      stats.up += got
    } else {
      stats.down += got
    }
    dst.write(scratch.unsafe_reinterpret_as_bytes()[:got]) catch {
      _ => break
    }
  }
}

///|
/// Read the request body, supporting both `Content-Length` and
/// `Transfer-Encoding: chunked`.
async fn read_request_body(
  client : @socket.Tcp,
  meta : @httpparse.ReqMeta,
) -> Bytes {
  if meta.chunked {
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
      buf.write_bytesview(client.read_exactly(size)[:])
      let _ = client.drop(2)
    }
    return buf.to_bytes()
  }
  match meta.bad_content_length {
    Some(v) => raise ProxyError("bad Content-Length: " + v)
    None => ()
  }
  match meta.content_length {
    Some(n) => {
      if n < 0 || n > max_body_size {
        raise ProxyError("body too large or invalid Content-Length")
      }
      if n == 0 {
        empty_bytes
      } else {
        client.read_exactly(n)
      }
    }
    None => empty_bytes
  }
}

///|
async fn send_simple(
  client : @socket.Tcp,
  code : Int32,
  reason : String,
) -> Unit {
  let body = "proxy error: " + reason + "\n"
  let buf = @buffer.Buffer(capacity=192)
  buf.write_bytesview(b"HTTP/1.1 ")
  buf.write_string_utf8(code.to_string())
  buf.write_byte(b' ')
  buf.write_string_utf8(reason)
  buf.write_bytesview(
    b"\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ",
  )
  buf.write_string_utf8(body.length().to_string())
  buf.write_bytesview(b"\r\nConnection: close\r\n\r\n")
  buf.write_string_utf8(body)
  client.write(buf.to_bytes())
}
