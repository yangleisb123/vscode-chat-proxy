///|
/// Blackbox tests: the shared contract must round-trip and match the
/// exact wire format produced by the backend.
fn sample_summary() -> @shared.FlowSummary {
  {
    id: 1,
    start_ms: 1795347011806.0,
    http_method: "POST",
    path: "/v1/chat/completions",
    status: 200,
    reason: "OK",
    intercepted: true,
    injected: true,
    pending: false,
    error: None,
    req_size: 69,
    resp_size: 283,
    duration_ms: 10,
    content_type: "application/json",
  }
}

///|
test "shared: FlowSummary json round-trip" {
  let s = sample_summary()
  let decoded : @shared.FlowSummary = @json.from_json(s.to_json())
  assert_eq(decoded, s)
}

///|
test "shared: FlowsResponse wire format" {
  let wire =
    #|{"total":1,"injected_total":1,"stored":1,"capacity":200,"intercept_enabled":true,"flows":[{"id":1,"start_ms":1795347011806,"http_method":"POST","path":"/v1/chat/completions","status":200,"reason":"OK","intercepted":true,"injected":true,"pending":false,"req_size":69,"resp_size":283,"duration_ms":10,"content_type":"application/json"}]}
  let resp : @shared.FlowsResponse = @json.from_json(@json.parse(wire))
  assert_eq(resp.total, 1)
  assert_true(resp.intercept_enabled)
  assert_eq(resp.flows.length(), 1)
  assert_eq(resp.flows[0], sample_summary())
  // Re-encoding parses back to the same value (key order independent).
  let again : @shared.FlowsResponse = @json.from_json(
    @json.parse(resp.to_json().stringify()),
  )
  assert_eq(again, resp)
}

///|
test "shared: FlowDetail wire format with nullable fields" {
  let wire =
    #|{"id":2,"start_ms":1795347011840,"duration_ms":319,"client_addr":"127.0.0.1:1","upstream":"127.0.0.1:8080","intercepted":true,"injected":true,"pending":false,"request":{"http_method":"POST","target":"/v1/chat/completions","headers":[["Content-Type","application/json"]],"body":"{}","truncated":false,"size":2},"upstream_request":{"body":"{\"a\":1}","truncated":false},"response":{"status":200,"reason":"OK","headers":[["Content-Type","text/event-stream"]],"body":"data: x\n\n","truncated":false,"size":9}}
  let d : @shared.FlowDetail = @json.from_json(@json.parse(wire))
  assert_eq(d.id, 2)
  assert_eq(d.request.headers, [("Content-Type", "application/json")])
  assert_true(d.upstream_request is Some(_))
  assert_true(d.response is Some(_))
  let decoded : @shared.FlowDetail = @json.from_json(
    @json.parse(d.to_json().stringify()),
  )
  assert_eq(decoded, d)
}

///|
test "shared: pending detail has null response" {
  let wire =
    #|{"id":3,"start_ms":1,"duration_ms":0,"client_addr":"c","upstream":"u","intercepted":false,"injected":false,"pending":true,"request":{"http_method":"GET","target":"/","headers":[],"body":"","truncated":false,"size":0}}
  let d : @shared.FlowDetail = @json.from_json(@json.parse(wire))
  assert_true(d.pending)
  assert_true(d.response is None)
  assert_true(d.upstream_request is None)
}
