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
  store.flush_pending() // eviction happens at flush (batched persistence)
  assert_true(store.find(1) is None) // evicted by capacity
  assert_true(store.find(3) is Some(_))
  assert_eq(store.total, 3)
  store.clear()
  assert_eq(store.total, 0)
  assert_eq(store.injected_total, 0)
  assert_true(store.find(3) is None)
  store.close()
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
test "flow: list and detail via shared contract" {
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
  let list = store.list_response()
  assert_eq(list.total, 1)
  assert_eq(list.injected_total, 1)
  assert_eq(list.flows.length(), 1)
  assert_eq(list.flows[0].injected, true)
  assert_eq(list.flows[0].path, "/v1/chat/completions")
  assert_eq(list.flows[0].pending, false)
  assert_eq(list.flows[0].content_type, "application/json")
  // The shared type must survive a JSON round-trip (wire format).
  let list2 : @shared.FlowsResponse = @json.from_json(
    @json.parse(list.to_json().stringify()),
  )
  assert_eq(list2, list)
  let d = store.detail(f.id).unwrap()
  assert_true(d.upstream_request is Some(_))
  assert_eq(d.request.body, "{}")
  assert_eq(d.response.unwrap().status, 200)
  assert_eq(d.response.unwrap().body, "{\"ok\":true}")
  let d2 : @shared.FlowDetail = @json.from_json(
    @json.parse(d.to_json().stringify()),
  )
  assert_eq(d2, d)
  store.close()
}

///|
test "flow: pending flow has null response in detail" {
  let store = FlowStore::new()
  let f = begin_test_flow(store, "/x")
  let d = store.detail(f.id).unwrap()
  assert_true(d.response is None)
  assert_true(d.pending)
  store.close()
}

///|
async test "flow: sqlite persists to temp dir, reloads, evicts, marks stale and clears" {
  let dir = @fs.tmpdir(prefix="vscode-chat-proxy-test")
  let store = FlowStore::open(dir, capacity=2)
  assert_eq(store.data_dir(), dir)
  let db_path = dir + "/monitor.sqlite"
  assert_true(@fs.exists(db_path))
  let f1 = begin_test_flow(store, "/one")
  f1.status = 200
  f1.reason = "OK"
  f1.response_headers = [("Content-Type", "application/json")]
  f1.response_body = @utf8.encode("{\"ok\":1}")
  f1.response_size = 8
  store.finish(f1)
  store.flush_pending()
  assert_true(@fs.exists(db_path))
  // Bodies are released from memory, but the detail API reads them back.
  assert_eq(f1.response_body.length(), 0)
  let d1 = store.detail(f1.id).unwrap()
  assert_eq(d1.response.unwrap().body, "{\"ok\":1}")
  store.close()

  // Simulate a proxy restart: a new store loads the same database.
  let store2 = FlowStore::open(dir, capacity=2)
  assert_eq(store2.list_response().stored, 1)
  assert_eq(store2.list_response().flows[0].path, "/one")
  let d2 = store2.detail(f1.id).unwrap()
  assert_eq(d2.response.unwrap().body, "{\"ok\":1}")

  // Capacity 2: a third finished flow evicts the oldest row.
  let f2 = begin_test_flow(store2, "/two")
  store2.finish(f2)
  let f3 = begin_test_flow(store2, "/three")
  store2.finish(f3)
  store2.flush_pending()
  assert_eq(store2.list_response().stored, 2)
  assert_true(store2.find(f1.id) is None)
  assert_true(store2.find(f2.id) is Some(_))

  // In-flight (begun, unfinished) flows are memory-only under batched
  // persistence: a crashed process leaves no row for them (best-effort monitor).
  let inflight = begin_test_flow(store2, "/inflight")
  store2.close()
  let store3 = FlowStore::open(dir, capacity=2)
  assert_true(store3.find(inflight.id) is None)

  store3.clear()
  assert_eq(store3.list_response().stored, 0)
  assert_eq(store3.list_response().total, 0)
  store3.close()
  @fs.rmdir(dir, recursive=true, allow_missing=true)
}

///|
test "monitor: intercept switch defaults on and toggles at runtime" {
  let store = FlowStore::new()
  assert_true(store.intercept_enabled())
  assert_true(store.list_response().intercept_enabled)
  store.set_intercept_enabled(false)
  assert_true(!store.intercept_enabled())
  assert_true(!store.list_response().intercept_enabled)
  store.set_intercept_enabled(true)
  assert_true(store.list_response().intercept_enabled)
  store.close()
}

///|
test "flow: disabled store skips recording while preserving intercept switch" {
  let store = FlowStore::disabled()
  assert_true(!store.is_recording())
  assert_true(store.intercept_enabled())
  store.set_intercept_enabled(false)
  assert_true(!store.intercept_enabled())
  let f = begin_test_flow(store, "/noop")
  store.finish(f)
  store.flush_pending()
  assert_eq(store.list_response().stored, 0)
  store.close()
}

///|
test "flow: burst flush pre-drops oldest excess beyond capacity" {
  let store = FlowStore::new(capacity=3)
  for i = 0; i < 8; i = i + 1 {
    let f = begin_test_flow(store, "/p" + i.to_string())
    f.status = 200
    store.finish(f)
  }
  store.flush_pending()
  let list = store.list_response()
  assert_eq(list.total, 8)
  assert_eq(list.stored, 3)
  assert_eq(list.flows[0].id, 8)
  assert_eq(list.flows[1].id, 7)
  assert_eq(list.flows[2].id, 6)
  assert_true(store.find(5) is None)
  assert_true(store.find(6) is Some(_))
  store.close()
}
