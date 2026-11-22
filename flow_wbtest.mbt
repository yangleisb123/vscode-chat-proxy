///|
fn begin_test_flow(store : FlowStore, target : String) -> Flow {
  store.begin(
    client_addr="127.0.0.1:1",
    http_method="POST",
    target~,
    request_headers=[],
    request_body=@utf8.encode("{}"),
    intercepted=true,
    upstream="u:80",
  )
}

///|
test "flow: begin / finish / find / clear" {
  let store = FlowStore::new(capacity=2)
  let f1 = begin_test_flow(store, "/a")
  assert_eq(f1.id, 1)
  assert_true(store.find(1) is Some(_))
  assert_true(!f1.finished)
  f1.injected = true
  f1.status = 200
  store.finish(f1)
  assert_true(f1.finished)
  store.finish(f1) // idempotent
  assert_eq(store.injected_total, 1)
  let _f2 = begin_test_flow(store, "/b")
  let _f3 = begin_test_flow(store, "/c")
  assert_true(store.find(1) is None) // evicted by ring buffer
  assert_true(store.find(3) is Some(_))
  assert_eq(store.total, 3)
  store.clear()
  assert_eq(store.total, 0)
  assert_eq(store.injected_total, 0)
  assert_true(store.find(3) is None)
}

///|
test "flow: cap_bytes" {
  let small = @utf8.encode("hello")
  let (b, t) = cap_bytes(small)
  assert_eq(b, small)
  assert_true(!t)
  let big = @utf8.encode(String::make(body_capture_limit + 10, 'x'))
  let (b2, t2) = cap_bytes(big)
  assert_eq(b2.length(), body_capture_limit)
  assert_true(t2)
}

///|
test "flow: decode_chunked_body" {
  let raw = @utf8.encode("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n")
  assert_eq(@utf8.decode_lossy(decode_chunked_body(raw)), "Wikipedia")
  let raw2 = @utf8.encode("4;ext=1\r\nWiki\r\n0\r\nTrailer: x\r\n\r\n")
  assert_eq(@utf8.decode_lossy(decode_chunked_body(raw2)), "Wiki")
  // Not chunked at all: fall back to raw bytes.
  let raw3 = @utf8.encode("{\"a\":1}")
  assert_eq(decode_chunked_body(raw3), raw3)
  // Truncated capture: keep what is available.
  let raw4 = @utf8.encode("a\r\n01234")
  assert_eq(@utf8.decode_lossy(decode_chunked_body(raw4)), "01234")
}

///|
test "flow: list and detail json" {
  let store = FlowStore::new()
  let f = begin_test_flow(store, "/v1/chat/completions")
  f.injected = true
  f.upstream_body = Some(@utf8.encode("{\"b\":2}"))
  f.status = 200
  f.reason = "OK"
  f.response_headers = [("Content-Type", "application/json")]
  f.response_body = @utf8.encode("{\"ok\":true}")
  f.response_size = 11
  store.finish(f)
  match store.list_json() {
    Object(obj) => {
      assert_true(obj.get("total") is Some(_))
      match obj.get("flows") {
        Some(Array(rows)) => {
          assert_eq(rows.length(), 1)
          match rows[0] {
            Object(row) => {
              assert_true(row.get("injected") is Some(True))
              assert_true(
                row.get("path") is Some(String("/v1/chat/completions")),
              )
              assert_true(row.get("pending") is Some(False))
            }
            _ => abort("expected row object")
          }
        }
        _ => abort("expected flows array")
      }
    }
    _ => abort("expected list object")
  }
  match f.detail_json() {
    Object(d) => {
      assert_true(d.get("upstream_request") is Some(Object(_)))
      match d.get("request") {
        Some(Object(req)) => assert_true(req.get("body") is Some(String("{}")))
        _ => abort("expected request object")
      }
      match d.get("response") {
        Some(Object(resp)) => {
          assert_true(resp.get("status") is Some(Number(_, ..)))
          assert_true(resp.get("body") is Some(String("{\"ok\":true}")))
        }
        _ => abort("expected response object")
      }
    }
    _ => abort("expected detail object")
  }
}

///|
test "flow: pending flow has null response in detail" {
  let store = FlowStore::new()
  let f = begin_test_flow(store, "/x")
  match f.detail_json() {
    Object(d) => {
      assert_true(d.get("response") is Some(Null))
      assert_true(d.get("pending") is Some(True))
    }
    _ => abort("expected detail object")
  }
}
