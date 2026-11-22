///|
/// Whitebox tests for the Elm update logic (pure, no DOM needed).
fn noop_emit() -> @rabbita.Emit[Msg] {
  @cmd.Emit(fn(_) { @rabbita.none })
}

///|
fn sample_summary(id : Int32, pending : Bool) -> @shared.FlowSummary {
  {
    id,
    start_ms: 1795347011806.0,
    http_method: "POST",
    path: "/v1/chat/completions",
    status: 200,
    reason: "OK",
    intercepted: true,
    injected: true,
    pending,
    error: None,
    req_size: 69,
    resp_size: 283,
    duration_ms: 10,
    content_type: "application/json",
  }
}

///|
test "frontend: select / filter / pause" {
  let emit = noop_emit()
  let (m1, _) = update(initial_model(), Select(5), emit)
  assert_eq(m1.selected, Some(5))
  assert_eq(m1.tab, RequestTab)
  assert_true(m1.detail is None)
  let (m2, _) = update(m1, Filter("chat"), emit)
  assert_eq(m2.filter, "chat")
  let (m3, _) = update(m2, TogglePause, emit)
  assert_true(m3.paused)
  let (m4, _) = update(m3, SetTab(ResponseTab), emit)
  assert_eq(m4.tab, ResponseTab)
}

///|
test "frontend: flows loaded updates stats and keeps selection" {
  let emit = noop_emit()
  let (m1, _) = update(initial_model(), Select(1), emit)
  let resp : @shared.FlowsResponse = {
    total: 2,
    injected_total: 1,
    stored: 2,
    capacity: 200,
    flows: [sample_summary(1, false), sample_summary(2, false)],
  }
  let (m2, _) = update(m1, FlowsLoaded(Ok(resp)), emit)
  assert_eq(m2.total, 2)
  assert_eq(m2.flows.length(), 2)
  assert_eq(m2.selected, Some(1))
  assert_true(!m2.offline)
}

///|
test "frontend: selection cleared when flow evicted" {
  let emit = noop_emit()
  let (m1, _) = update(initial_model(), Select(9), emit)
  let resp : @shared.FlowsResponse = {
    total: 1,
    injected_total: 0,
    stored: 1,
    capacity: 200,
    flows: [sample_summary(1, false)],
  }
  let (m2, _) = update(m1, FlowsLoaded(Ok(resp)), emit)
  assert_true(m2.selected is None)
  assert_true(m2.detail is None)
}

///|
test "frontend: load failure marks offline" {
  let emit = noop_emit()
  let (m, _) = update(
    initial_model(),
    FlowsLoaded(Err(@rhttp.HttpError::RequestError("boom"))),
    emit,
  )
  assert_true(m.offline)
}

///|
test "frontend: filtering matches path and method" {
  let flows = [
    sample_summary(1, false),
    { ..sample_summary(2, false), path: "/v1/models", http_method: "GET", },
  ]
  let m = { ..initial_model(), flows, filter: "models", }
  assert_eq(filtered_flows(m).length(), 1)
  let m2 = { ..m, filter: "post", }
  assert_eq(filtered_flows(m2).length(), 1)
  let m3 = { ..m, filter: "", }
  assert_eq(filtered_flows(m3).length(), 2)
}

///|
test "frontend: size formatting" {
  assert_eq(fmt_size(512), "512 B")
  assert_eq(fmt_size(2048), "2.0 K")
  assert_eq(fmt_size(1536), "1.5 K")
  assert_eq(fmt_size(1048576), "1.00 M")
}

///|
test "frontend: pretty prints json bodies" {
  assert_eq(pretty("{\"a\":1}", "application/json"), "{\n  \"a\": 1\n}")
  assert_eq(pretty("data: x", "text/event-stream"), "data: x")
  assert_eq(pretty("", "application/json"), "（空）")
  assert_eq(pretty("{bad json", "application/json"), "{bad json")
}
