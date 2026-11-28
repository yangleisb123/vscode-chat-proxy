///|
/// Test helper: read response header lines after a pre-read status line and
/// delegate to `forward_response_head_and_body`.
async fn forward_response_for_test(
  client : @socket.Tcp,
  conn : @socket.Tcp,
  flow : @monitor.Flow,
  status_line : String,
  client_keep : Bool,
) -> (Bool, Bool) {
  let sb = StringBuilder(capacity=256)
  let mut first = true
  for ;; {
    match conn.read_until("\r\n") {
      Some("") | None => break
      Some(l) => {
        if !first {
          sb.write_string("\r\n")
        }
        sb.write_string(l)
        first = false
      }
    }
  }
  forward_response_head_and_body(
    client,
    conn,
    flow,
    status_line,
    sb.to_string().clamped_view(),
    client_keep,
    "",
    true,
  )
}

///|
/// Bind a loopback TcpServer on the first free port in a private range.
/// Each test uses its own range so parallel tests never share ports.
async fn local_test_server(base_port : Int32) -> (@socket.TcpServer, Int32) {
  for port in base_port..<(base_port + 10) {
    try {
      let addr = @socket.Addr::new(0x7f000001, port)
      let server = @socket.TcpServer(addr, reuse_addr=true)
      return (server, port)
    } catch {
      _ => ()
    }
  }
  fail("no free local port for proxy test")
}

///|
/// Run `forward_response` against a fake upstream that sends `payload`
/// (headers + chunked body; the status line is passed separately) and return
/// everything the client side received, plus the recorded flow.
async fn relay_chunked(
  payload : String,
  base_port~ : Int32,
) -> (String, @monitor.Flow) {
  let (up_server, up_port) = local_test_server(base_port)
  let (cl_server, cl_port) = local_test_server(base_port + 10)
  let client_peer = @socket.Tcp::connect_to_host("127.0.0.1", port=cl_port)
  let (client_side, _) = cl_server.accept()
  let upstream_conn = @socket.Tcp::connect_to_host("127.0.0.1", port=up_port)
  let (upstream_side, _) = up_server.accept()
  upstream_side.write(payload)
  let flow : @monitor.Flow = {
    id: 1,
    start_ms: 0UL,
    client_addr: "127.0.0.1:0",
    http_method: "POST",
    target: "http://127.0.0.1/v1/chat/completions",
    request_headers: [],
    request_size: 0,
    intercepted: false,
    upstream: "127.0.0.1:0",
    request_body: b"",
    request_truncated: false,
    injected: false,
    upstream_body: None,
    upstream_truncated: false,
    status: 0,
    reason: "",
    response_headers: [],
    response_body: b"",
    response_size: 0,
    response_truncated: false,
    end_ms: 0UL,
    error: None,
    finished: false,
    persisted: false,
  }
  let (framed, reusable) = forward_response_for_test(
    client_side, upstream_conn, flow, "HTTP/1.1 200 OK", true,
  )
  assert_true(framed)
  assert_true(reusable)
  // Close the proxy-facing side so the client peer reads to EOF.
  client_side.close()
  let buf = @buffer.Buffer()
  for ;; {
    match client_peer.read_some(max_len=65536) {
      Some(chunk) => buf.write_bytesview(chunk.clamped_view())
      None => break
    }
  }
  client_peer.close()
  upstream_side.close()
  upstream_conn.close()
  up_server.close()
  cl_server.close()
  (@utf8.decode(buf.to_bytes()), flow)
}

///|
/// Regression: the empty line terminating the chunked message (after the
/// 0-size last chunk) must be relayed to the client. Without it, keep-alive
/// clients receive the whole body but wait forever for the end of the message.
async test "forward_response relays chunked terminator CRLF" {
  let (got, flow) = relay_chunked(
    "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
    base_port=39871,
  )
  assert_eq(
    got, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
  )
  assert_eq(@utf8.decode(flow.response_body), "hello")
}

///|
async test "forward_response relays chunked trailers and terminator" {
  let (got, flow) = relay_chunked(
    "Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Check: ok\r\n\r\n",
    base_port=39901,
  )
  assert_eq(
    got, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n0\r\nX-Check: ok\r\n\r\n",
  )
  assert_eq(@utf8.decode(flow.response_body), "hello")
}

///|
async test "forward_response treats 204 No Content as framed keep-alive without waiting for EOF" {
  let (up_server, up_port) = local_test_server(39921)
  let (cl_server, cl_port) = local_test_server(39931)
  let client_peer = @socket.Tcp::connect_to_host("127.0.0.1", port=cl_port)
  let (client_side, _) = cl_server.accept()
  let upstream_conn = @socket.Tcp::connect_to_host("127.0.0.1", port=up_port)
  let (upstream_side, _) = up_server.accept()
  upstream_side.write("X-Empty: 1\r\n\r\n")
  let flow : @monitor.Flow = {
    id: 1,
    start_ms: 0UL,
    client_addr: "127.0.0.1:0",
    http_method: "DELETE",
    target: "/v1/item",
    request_headers: [],
    request_size: 0,
    intercepted: false,
    upstream: "127.0.0.1:0",
    request_body: b"",
    request_truncated: false,
    injected: false,
    upstream_body: None,
    upstream_truncated: false,
    status: 0,
    reason: "",
    response_headers: [],
    response_body: b"",
    response_size: 0,
    response_truncated: false,
    end_ms: 0UL,
    error: None,
    finished: false,
    persisted: false,
  }
  let (framed, reusable) = forward_response_for_test(
    client_side, upstream_conn, flow, "HTTP/1.1 204 No Content", true,
  )
  assert_true(framed)
  assert_true(reusable)
  client_side.close()
  let got = @utf8.decode(client_peer.read_all().binary())
  assert_eq(
    got, "HTTP/1.1 204 No Content\r\nX-Empty: 1\r\nConnection: keep-alive\r\n\r\n",
  )
  client_peer.close()
  upstream_side.close()
  upstream_conn.close()
  up_server.close()
  cl_server.close()
}
