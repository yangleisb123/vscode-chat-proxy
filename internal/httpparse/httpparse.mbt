///|
pub(all) struct RequestHead {
  http_method : String
  target : String
  headers : Array[(String, String)]
}

///|
/// Metadata extracted in a single pass while parsing request headers.
pub(all) struct ReqMeta {
  host : String?
  connection : String?
  upgrade : Bool
  expect_100 : Bool
  content_length : Int32?
  bad_content_length : String?
  chunked : Bool
}

///|
/// Metadata extracted in a single pass while parsing response headers.
pub(all) struct RespMeta {
  connection : String?
  content_length : Int32?
  chunked : Bool
}

///|
/// Zero-allocation ASCII case-insensitive substring check.
/// `needle_lower` MUST already be lowercase ASCII.
pub fn contains_ignore_ascii_case(
  haystack : StringView,
  needle_lower : StringView,
) -> Bool {
  let nlen = needle_lower.length()
  if nlen == 0 {
    return true
  }
  let hlen = haystack.length()
  if nlen > hlen {
    return false
  }
  let limit = hlen - nlen
  let first = needle_lower.code_unit_at(0)
  let mut i = 0
  while i <= limit {
    let c0 = haystack.code_unit_at(i)
    let lc0 = if c0 >= 65 && c0 <= 90 { c0 + 32 } else { c0 }
    if lc0 == first {
      let mut j = 1
      while j < nlen {
        let ch = haystack.code_unit_at(i + j)
        let lch = if ch >= 65 && ch <= 90 { ch + 32 } else { ch }
        if lch != needle_lower.code_unit_at(j) {
          break
        }
        j += 1
      }
      if j == nlen {
        return true
      }
    }
    i += 1
  }
  false
}

///|
/// Fast hop-by-hop / proxy-managed header filter. Rejects common headers
/// (`Authorization`, `Content-Type`, `User-Agent`, `Accept`, …) in 1–2 ops
/// instead of 11 sequential case-insensitive string comparisons.
fn is_managed_or_hop_by_hop(n : StringView) -> Bool {
  let len = n.length()
  if len < 2 || len > 19 {
    return false
  }
  let c0 = n.code_unit_at(0)
  let lc0 = if c0 >= 65 && c0 <= 90 { c0 + 32 } else { c0 }
  match lc0 {
    'h' => len == 4 && n.equal_ignore_ascii_case("host")
    'c' =>
      (len == 10 && n.equal_ignore_ascii_case("connection")) ||
      (len == 14 && n.equal_ignore_ascii_case("content-length"))
    't' =>
      (len == 2 && n.equal_ignore_ascii_case("te")) ||
      (len == 7 && n.equal_ignore_ascii_case("trailer")) ||
      (len == 17 && n.equal_ignore_ascii_case("transfer-encoding"))
    'e' => len == 6 && n.equal_ignore_ascii_case("expect")
    'k' => len == 10 && n.equal_ignore_ascii_case("keep-alive")
    'p' =>
      (len == 16 && n.equal_ignore_ascii_case("proxy-connection")) ||
      (len == 19 && n.equal_ignore_ascii_case("proxy-authorization"))
    'u' => len == 7 && n.equal_ignore_ascii_case("upgrade")
    _ => false
  }
}

///|
/// Parse a request line like `POST /v1/chat/completions HTTP/1.1`.
pub fn parse_request_line(line : String) -> (String, String, String)? {
  parse_request_line_view(line.clamped_view())
}

///|
fn parse_request_line_view(line : StringView) -> (String, String, String)? {
  match line.split_once(" ") {
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
/// Parse a full HTTP request head block (everything before `\r\n\r\n`) in one
/// pass, skipping any leading empty lines and extracting routing/framing
/// headers without extra scans or `.to_lower()` allocations.
pub fn parse_request_head_block(
  block : String,
) -> (String, String, String, Array[(String, String)], ReqMeta)? {
  let mut rest = block.clamped_view()
  let mut req_line = rest
  for ;; {
    match rest.split_once("\r\n") {
      Some((line, tail)) =>
        if line.is_empty() {
          rest = tail
          continue
        } else {
          req_line = line
          rest = tail
          break
        }
      None => {
        req_line = rest
        rest = rest.clamped_view(end=0)
        break
      }
    }
  }
  let (http_method, target, version) = match parse_request_line_view(req_line) {
    Some(parts) => parts
    None => return None
  }
  let headers : Array[(String, String)] = []
  let mut host : String? = None
  let mut connection : String? = None
  let mut upgrade = false
  let mut expect_100 = false
  let mut content_length : Int32? = None
  let mut bad_content_length : String? = None
  let mut chunked = false
  while !rest.is_empty() {
    let line = match rest.split_once("\r\n") {
      Some((l, tail)) => {
        rest = tail
        l
      }
      None => {
        let l = rest
        rest = rest.clamped_view(end=0)
        l
      }
    }
    match line.split_once(":") {
      Some((name, raw_val)) if !name.is_empty() => {
        let val_view = raw_val.trim()
        let val = val_view.to_owned()
        headers.push((name.to_owned(), val))
        let nlen = name.length()
        let c0 = name.code_unit_at(0)
        let lc0 = if c0 >= 65 && c0 <= 90 { c0 + 32 } else { c0 }
        match lc0 {
          'h' =>
            if host is None && nlen == 4 && name.equal_ignore_ascii_case("host") {
              host = Some(val)
            }
          'c' =>
            if connection is None &&
              nlen == 10 &&
              name.equal_ignore_ascii_case("connection") {
              connection = Some(val)
            } else if content_length is None &&
              bad_content_length is None &&
              nlen == 14 &&
              name.equal_ignore_ascii_case("content-length") {
              try {
                content_length = Some(@string.parse_int(val_view))
              } catch {
                _ => bad_content_length = Some(val)
              }
            }
          't' =>
            if !chunked &&
              nlen == 17 &&
              name.equal_ignore_ascii_case("transfer-encoding") {
              if contains_ignore_ascii_case(val_view, "chunked") {
                chunked = true
              }
            }
          'u' =>
            if !upgrade && nlen == 7 && name.equal_ignore_ascii_case("upgrade") {
              upgrade = true
            }
          'e' =>
            if !expect_100 &&
              nlen == 6 &&
              name.equal_ignore_ascii_case("expect") {
              if contains_ignore_ascii_case(val_view, "100-continue") {
                expect_100 = true
              }
            }
          _ => ()
        }
      }
      _ => ()
    }
  }
  let meta : ReqMeta = {
    host,
    connection,
    upgrade,
    expect_100,
    content_length,
    bad_content_length,
    chunked,
  }
  Some((http_method, target, version, headers, meta))
}

///|
/// Parse response header lines (the part after `status_line\r\n` and before
/// `\r\n\r\n`) in a single pass.
pub fn parse_response_headers_block(
  headers_block : StringView,
) -> (Array[(String, String)], RespMeta) {
  let headers : Array[(String, String)] = []
  let mut connection : String? = None
  let mut content_length : Int32? = None
  let mut chunked = false
  let mut rest = headers_block
  while !rest.is_empty() {
    let line = match rest.split_once("\r\n") {
      Some((l, tail)) => {
        rest = tail
        l
      }
      None => {
        let l = rest
        rest = rest.clamped_view(end=0)
        l
      }
    }
    match line.split_once(":") {
      Some((name, raw_val)) if !name.is_empty() => {
        let val_view = raw_val.trim()
        let val = val_view.to_owned()
        headers.push((name.to_owned(), val))
        let nlen = name.length()
        let c0 = name.code_unit_at(0)
        let lc0 = if c0 >= 65 && c0 <= 90 { c0 + 32 } else { c0 }
        match lc0 {
          'c' =>
            if connection is None &&
              nlen == 10 &&
              name.equal_ignore_ascii_case("connection") {
              connection = Some(val)
            } else if content_length is None &&
              nlen == 14 &&
              name.equal_ignore_ascii_case("content-length") {
              let n = @string.parse_int(val_view) catch { _ => -1 }
              content_length = Some(n)
            }
          't' =>
            if !chunked &&
              nlen == 17 &&
              name.equal_ignore_ascii_case("transfer-encoding") {
              if contains_ignore_ascii_case(val_view, "chunked") {
                chunked = true
              }
            }
          _ => ()
        }
      }
      _ => ()
    }
  }
  (headers, { connection, content_length, chunked, })
}

///|
/// Parse a response status line like `HTTP/1.1 200 OK`.
pub fn parse_status_line(line : String) -> (Int32, String)? {
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
pub fn parse_header_line(line : String) -> (String, String)? {
  match line.clamped_view().split_once(":") {
    Some((name, value)) if !name.is_empty() =>
      Some((name.to_owned(), value.trim().to_owned()))
    _ => None
  }
}

///|
/// Case-insensitive header lookup.
pub fn header_value(head : RequestHead, name : String) -> String? {
  for pair in head.headers {
    if pair.0.clamped_view().equal_ignore_ascii_case(name) {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Zero-allocation slice view of the path part of a request target.
fn target_path_view(target : String) -> StringView {
  let mut v = target.clamped_view()
  if v.has_prefix("http://") || v.has_prefix("https://") {
    let rest = v.clamped_view(start=8)
    v = match rest.find("/") {
      Some(i) => rest.clamped_view(start=i)
      None => rest.clamped_view(end=0)
    }
  }
  match v.find("?") {
    Some(i) => v.clamped_view(end=i)
    None => v
  }
}

///|
/// Path part of a request target, without the query string.
/// Handles origin-form (`/v1/...`) and absolute-form (`http://host/v1/...`).
pub fn target_path(target : String) -> String {
  let path = target_path_view(target)
  if path.is_empty() {
    "/"
  } else {
    path.to_owned()
  }
}

///|
/// Whether this request targets the Chat Completions API:
/// `POST` to a path ending with `/v1/chat/completions`.
pub fn is_chat_completions(http_method : String, target : String) -> Bool {
  http_method == "POST" &&
  target_path_view(target).has_suffix("/v1/chat/completions")
}

///|
/// Parse an authority (`host`, `host:port`, `[ipv6]:port`) with a default
/// port when none is given. Used for CONNECT targets and `Host` headers.
pub fn parse_authority(s : String, default_port : Int32) -> (String, Int32)? {
  parse_authority_view(s.clamped_view(), default_port)
}

///|
fn parse_authority_view(
  raw : StringView,
  default_port : Int32,
) -> (String, Int32)? {
  let v = raw.trim()
  if v.is_empty() {
    return None
  }
  let (host, port_str) = if v.has_prefix("[") {
    match v.split_once("]:") {
      Some((h, p)) => (h.clamped_view(start=1).to_owned(), Some(p))
      None =>
        match v.split_once("]") {
          Some((h, _)) => (h.clamped_view(start=1).to_owned(), None)
          None => return None
        }
    }
  } else {
    match v.split_once(":") {
      Some((h, p)) => (h.to_owned(), Some(p))
      None => (v.to_owned(), None)
    }
  }
  if host.is_empty() {
    return None
  }
  let port = match port_str {
    Some(p) => @string.parse_int(p.trim()) catch { _ => return None }
    None => default_port
  }
  if port < 1 || port > 65535 {
    return None
  }
  Some((host, port))
}

///|
/// Split an absolute-form `http://host[:port]/path?query` target into
/// (host, port, path-with-query). Returns None for non-http schemes
/// (https needs MITM, which this proxy does not do) or malformed URLs.
pub fn absolute_http_target(target : String) -> (String, Int32, String)? {
  let v = target.clamped_view()
  if !v.has_prefix("http://") {
    return None
  }
  let rest = v.clamped_view(start=7)
  let (authority, path) = match rest.find("/") {
    Some(i) => (rest.clamped_view(end=i), rest.clamped_view(start=i).to_owned())
    None => (rest, "/")
  }
  let (host, port) = match parse_authority_view(authority, 80) {
    Some(pair) => pair
    None => return None
  }
  Some((host, port, path))
}

///|
/// Write the keep-alive upstream request head directly into a UTF-8 `@buffer.Buffer`
/// (linear time, zero intermediate Strings, no second UTF-16->UTF-8 encode pass).
pub fn write_upstream_head_keepalive(
  buf : @buffer.Buffer,
  head : RequestHead,
  upstream_host : String,
  upstream_port : Int32,
  body_len : Int32,
  send_content_length : Bool,
) -> Unit {
  buf.write_string_utf8(head.http_method)
  buf.write_bytes(b" ")
  buf.write_string_utf8(head.target)
  buf.write_bytes(b" HTTP/1.1\r\nHost: ")
  buf.write_string_utf8(upstream_host)
  if upstream_port != 80 {
    buf.write_byte(b':')
    buf.write_string_utf8(upstream_port.to_string())
  }
  buf.write_bytes(b"\r\n")
  for pair in head.headers {
    if is_managed_or_hop_by_hop(pair.0.clamped_view()) {
      continue
    }
    buf.write_string_utf8(pair.0)
    buf.write_bytes(b": ")
    buf.write_string_utf8(pair.1)
    buf.write_bytes(b"\r\n")
  }
  if send_content_length {
    buf.write_bytes(b"Content-Length: ")
    buf.write_string_utf8(body_len.to_string())
    buf.write_bytes(b"\r\n")
  }
  buf.write_bytes(b"Connection: keep-alive\r\n\r\n")
}

///|
fn build_upstream_head_with_conn(
  head : RequestHead,
  upstream_host : String,
  upstream_port : Int32,
  body_len : Int32,
  send_content_length : Bool,
  conn_value : String,
) -> String {
  let sb = StringBuilder(capacity=256)
  sb.write_string(head.http_method)
  sb.write_string(" ")
  sb.write_string(head.target)
  sb.write_string(" HTTP/1.1\r\nHost: ")
  sb.write_string(upstream_host)
  if upstream_port != 80 {
    sb.write_char(':')
    sb.write_string(upstream_port.to_string())
  }
  sb.write_string("\r\n")
  for pair in head.headers {
    if is_managed_or_hop_by_hop(pair.0.clamped_view()) {
      continue
    }
    sb.write_string(pair.0)
    sb.write_string(": ")
    sb.write_string(pair.1)
    sb.write_string("\r\n")
  }
  if send_content_length {
    sb.write_string("Content-Length: ")
    sb.write_string(body_len.to_string())
    sb.write_string("\r\n")
  }
  sb.write_string("Connection: ")
  sb.write_string(conn_value)
  sb.write_string("\r\n\r\n")
  sb.to_string()
}

///|
/// Like `build_upstream_head` but asks the upstream to keep the connection
/// alive so it can be returned to the reuse pool.
pub fn build_upstream_head_keepalive(
  head : RequestHead,
  upstream_host : String,
  upstream_port : Int32,
  body_len : Int32,
  send_content_length : Bool,
) -> String {
  build_upstream_head_with_conn(
    head, upstream_host, upstream_port, body_len, send_content_length, "keep-alive",
  )
}

///|
/// Rebuild the request head for the upstream connection:
/// rewrite `Host`, force `Connection: close`, drop hop-by-hop headers
/// and set `Content-Length` to the (possibly rewritten) body size.
pub fn build_upstream_head(
  head : RequestHead,
  upstream_host : String,
  upstream_port : Int32,
  body_len : Int32,
  send_content_length : Bool,
) -> String {
  build_upstream_head_with_conn(
    head, upstream_host, upstream_port, body_len, send_content_length, "close",
  )
}
