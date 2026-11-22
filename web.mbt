///|
/// Run the monitor web server (mitmweb-style UI + JSON API).
pub async fn run_web_server(addr : @socket.Addr, store : FlowStore) -> Unit {
  let server = @socket.TcpServer(addr, reuse_addr=true)
  server.run_forever((conn, _) => handle_web_connection(conn, store))
}

///|
async fn handle_web_connection(conn : @socket.Tcp, store : FlowStore) -> Unit {
  handle_web_inner(conn, store) catch {
    e => println("[web] connection error: " + e.to_string())
  }
}

///|
async fn handle_web_inner(conn : @socket.Tcp, store : FlowStore) -> Unit {
  let line = match conn.read_until("\r\n") {
    Some(l) if !l.is_empty() => l
    _ => return
  }
  let (http_method, target, _version) = match parse_request_line(line) {
    Some(parts) => parts
    None => {
      send_text(conn, 400, "Bad Request", "text/plain", "bad request")
      return
    }
  }
  // Drain headers (the monitor API never needs a request body).
  for ;; {
    match conn.read_until("\r\n") {
      Some("") => break
      Some(_) => ()
      None => return
    }
  }
  let path = target_path(target)
  if http_method == "GET" && path == "/" {
    send_text(conn, 200, "OK", "text/html; charset=utf-8", web_page)
  } else if http_method == "GET" && path == "/api/flows" {
    send_json(conn, store.list_json())
  } else if http_method == "GET" && path.has_prefix("/api/flows/") {
    let id_str = path.clamped_view(start=11).to_owned()
    let id = @string.parse_int(id_str.clamped_view()) catch {
      _ => {
        send_text(conn, 404, "Not Found", "text/plain", "invalid flow id")
        return
      }
    }
    match store.find(id) {
      Some(flow) => send_json(conn, flow.detail_json())
      None => send_text(conn, 404, "Not Found", "text/plain", "flow not found")
    }
  } else if http_method == "DELETE" && path == "/api/flows" {
    store.clear()
    send_json(conn, Json::object({ "ok": Json::boolean(true) }))
  } else {
    send_text(conn, 404, "Not Found", "text/plain", "not found")
  }
}

///|
async fn send_json(conn : @socket.Tcp, json : Json) -> Unit {
  send_text(
    conn,
    200,
    "OK",
    "application/json; charset=utf-8",
    json.stringify(),
  )
}

///|
async fn send_text(
  conn : @socket.Tcp,
  code : Int32,
  reason : String,
  content_type : String,
  body : String,
) -> Unit {
  let bytes = @utf8.encode(body)
  let head = "HTTP/1.1 " +
    code.to_string() +
    " " +
    reason +
    "\r\n" +
    "Content-Type: " +
    content_type +
    "\r\n" +
    "Content-Length: " +
    bytes.length().to_string() +
    "\r\n" +
    "Cache-Control: no-store\r\n" +
    "Connection: close\r\n\r\n"
  conn.write(head)
  conn.write(bytes)
}
