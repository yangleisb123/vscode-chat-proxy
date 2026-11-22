///|
test "http: parse_request_line" {
  assert_eq(
    parse_request_line("POST /v1/chat/completions HTTP/1.1"),
    Some(("POST", "/v1/chat/completions", "HTTP/1.1")),
  )
  assert_eq(
    parse_request_line("GET / HTTP/1.0"),
    Some(("GET", "/", "HTTP/1.0")),
  )
  assert_true(parse_request_line("garbage") is None)
  assert_true(parse_request_line("POST /x") is None)
  assert_true(parse_request_line("POST /x FOO/1.1") is None)
}

///|
test "http: parse_header_line" {
  assert_eq(
    parse_header_line("Content-Type: application/json"),
    Some(("Content-Type", "application/json")),
  )
  assert_eq(parse_header_line("X-Empty:"), Some(("X-Empty", "")))
  assert_true(parse_header_line("no colon here") is None)
}

///|
test "http: target_path and is_chat_completions" {
  assert_eq(
    target_path("/v1/chat/completions?stream=true"),
    "/v1/chat/completions",
  )
  assert_eq(
    target_path("http://api.example.com/v1/chat/completions"),
    "/v1/chat/completions",
  )
  assert_eq(target_path("https://api.example.com"), "/")
  assert_true(is_chat_completions("POST", "/v1/chat/completions"))
  assert_true(is_chat_completions("POST", "/openai/v1/chat/completions?x=1"))
  assert_true(!is_chat_completions("GET", "/v1/chat/completions"))
  assert_true(!is_chat_completions("POST", "/v1/completions"))
  assert_true(!is_chat_completions("POST", "/v1/chat/completions/extra"))
}

///|
test "http: header_value is case insensitive" {
  let head : RequestHead = {
    http_method: "POST",
    target: "/",
    headers: [("Content-Type", "application/json"), ("X-Foo", "bar")],
  }
  assert_eq(header_value(head, "content-type"), Some("application/json"))
  assert_eq(header_value(head, "X-FOO"), Some("bar"))
  assert_eq(header_value(head, "missing"), None)
}

///|
test "http: build_upstream_head rewrites hop-by-hop headers" {
  let head : RequestHead = {
    http_method: "POST",
    target: "/v1/chat/completions",
    headers: [
      ("Host", "127.0.0.1:8787"),
      ("Content-Length", "10"),
      ("Connection", "keep-alive"),
      ("Authorization", "Bearer sk-x"),
      ("Expect", "100-continue"),
    ],
  }
  let out = build_upstream_head(head, "api.local", 8080, 42, true)
  assert_true(out.has_prefix("POST /v1/chat/completions HTTP/1.1\r\n"))
  assert_true(out.contains("Host: api.local:8080\r\n"))
  assert_true(out.contains("Content-Length: 42\r\n"))
  assert_true(out.contains("Authorization: Bearer sk-x\r\n"))
  assert_true(out.contains("Connection: close\r\n"))
  assert_true(!out.contains("keep-alive"))
  assert_true(!out.contains("Expect"))
  assert_true(!out.contains("127.0.0.1:8787"))
  assert_true(out.has_suffix("\r\n\r\n"))
}

///|
test "http: build_upstream_head omits port 80 and content-length when asked" {
  let head : RequestHead = {
    http_method: "GET",
    target: "/v1/models",
    headers: [],
  }
  let out = build_upstream_head(head, "api.local", 80, 0, false)
  assert_true(out.contains("Host: api.local\r\n"))
  assert_true(!out.contains("Content-Length"))
}
