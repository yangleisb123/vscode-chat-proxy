///|
priv struct RequestHead {
  http_method : String
  target : String
  headers : Array[(String, String)]
}

///|
/// Parse a request line like `POST /v1/chat/completions HTTP/1.1`.
fn parse_request_line(line : String) -> (String, String, String)? {
  match line.clamped_view().split_once(" ") {
    Some((http_method, rest)) =>
      match rest.split_once(" ") {
        Some((target, version)) =>
          if version.has_prefix("HTTP/") && !target.is_empty() {
            Some(
              (http_method.to_owned(), target.to_owned(), version.to_owned()),
            )
          } else {
            None
          }
        None => None
      }
    None => None
  }
}

///|
/// Parse a response status line like `HTTP/1.1 200 OK`.
fn parse_status_line(line : String) -> (Int32, String)? {
  match line.clamped_view().split_once(" ") {
    Some((version, rest)) if version.has_prefix("HTTP/") => {
      let (code_str, reason) = match rest.split_once(" ") {
        Some((c, r)) => (c, r.to_owned())
        None => (rest, "")
      }
      let code = @string.parse_int(code_str) catch { _ => return None }
      Some((code, reason))
    }
    _ => None
  }
}

///|
/// Parse a header line like `Content-Type: application/json`.
fn parse_header_line(line : String) -> (String, String)? {
  match line.clamped_view().split_once(":") {
    Some((name, value)) if !name.is_empty() =>
      Some((name.to_owned(), value.trim().to_owned()))
    _ => None
  }
}

///|
/// Case-insensitive header lookup.
fn header_value(head : RequestHead, name : String) -> String? {
  for pair in head.headers {
    if pair.0.clamped_view().equal_ignore_ascii_case(name) {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Path part of a request target, without the query string.
/// Handles origin-form (`/v1/...`) and absolute-form (`http://host/v1/...`).
fn target_path(target : String) -> String {
  let mut v = target.clamped_view()
  if v.has_prefix("http://") || v.has_prefix("https://") {
    let rest = v.clamped_view(start=8)
    v = match rest.find("/") {
      Some(i) => rest.clamped_view(start=i)
      None => rest.clamped_view(end=0)
    }
  }
  let path = match v.find("?") {
    Some(i) => v.clamped_view(end=i)
    None => v
  }
  if path.is_empty() {
    "/"
  } else {
    path.to_owned()
  }
}

///|
/// Whether this request targets the Chat Completions API:
/// `POST` to a path ending with `/v1/chat/completions`.
fn is_chat_completions(http_method : String, target : String) -> Bool {
  http_method == "POST" &&
  target_path(target).has_suffix("/v1/chat/completions")
}

///|
/// Rebuild the request head for the upstream connection:
/// rewrite `Host`, force `Connection: close`, drop hop-by-hop headers
/// and set `Content-Length` to the (possibly rewritten) body size.
fn build_upstream_head(
  head : RequestHead,
  upstream_host : String,
  upstream_port : Int32,
  body_len : Int32,
  send_content_length : Bool,
) -> String {
  let authority = if upstream_port == 80 {
    upstream_host
  } else {
    upstream_host + ":" + upstream_port.to_string()
  }
  let mut out = head.http_method + " " + head.target + " HTTP/1.1\r\n"
  out = out + "Host: " + authority + "\r\n"
  for pair in head.headers {
    let n = pair.0.clamped_view()
    if n.equal_ignore_ascii_case("host") ||
      n.equal_ignore_ascii_case("connection") ||
      n.equal_ignore_ascii_case("content-length") ||
      n.equal_ignore_ascii_case("transfer-encoding") ||
      n.equal_ignore_ascii_case("expect") ||
      n.equal_ignore_ascii_case("keep-alive") ||
      n.equal_ignore_ascii_case("proxy-connection") ||
      n.equal_ignore_ascii_case("te") ||
      n.equal_ignore_ascii_case("trailer") ||
      n.equal_ignore_ascii_case("upgrade") {
      continue
    }
    out = out + pair.0 + ": " + pair.1 + "\r\n"
  }
  if send_content_length {
    out = out + "Content-Length: " + body_len.to_string() + "\r\n"
  }
  out + "Connection: close\r\n\r\n"
}
