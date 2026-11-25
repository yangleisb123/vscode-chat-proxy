///|
/// Monitor frontend: an Elm-architecture app built with rabbita,
/// compiled to JavaScript. The API contract types come from the shared
/// package, so frontend and backend cannot drift apart.

///|
#derive(Eq, Debug)
enum Tab {
  RequestTab
  ResponseTab
  InjectedTab
}

///|
#derive(Eq, Debug)
struct Model {
  flows : Array[@shared.FlowSummary]
  total : Int32
  injected_total : Int32
  stored : Int32
  capacity : Int32
  selected : Int32?
  detail : @shared.FlowDetail?
  /// Cached pretty-printed bodies for the currently selected `detail`,
  /// computed once on `DetailLoaded` instead of re-parsing JSON on every
  /// 1.5s poll tick or filter keystroke.
  pretty_req : String
  pretty_upstream : String
  pretty_resp : String
  tab : Tab
  filter : String
  paused : Bool
  offline : Bool
  intercept_enabled : Bool
}

///|
enum Msg {
  Tick
  FlowsLoaded(Result[@shared.FlowsResponse, Error])
  DetailLoaded(Result[@shared.FlowDetail, Error])
  Select(Int32)
  SetTab(Tab)
  Filter(String)
  TogglePause
  Clear
  Cleared
  ToggleIntercept
  InterceptToggled
}

///|
fn initial_model() -> Model {
  {
    flows: [],
    total: 0,
    injected_total: 0,
    stored: 0,
    capacity: 0,
    selected: None,
    detail: None,
    pretty_req: "",
    pretty_upstream: "",
    pretty_resp: "",
    tab: RequestTab,
    filter: "",
    paused: false,
    offline: false,
    intercept_enabled: true,
  }
}

///|
fn fetch_flows(emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  @rhttp.get("/api/flows").expect_json(result => emit(FlowsLoaded(result)))
}

///|
fn fetch_detail(emit : @rabbita.Emit[Msg], id : Int32) -> @rabbita.Cmd {
  @rhttp.get("/api/flows/" + id.to_string()).expect_json(result => {
    emit(DetailLoaded(result))
  })
}

///|
fn update(
  model : Model,
  msg : Msg,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  match msg {
    Tick => (model, fetch_flows(emit))
    FlowsLoaded(Ok(resp)) => {
      let m : Model = {
        ..model,
        flows: resp.flows,
        total: resp.total,
        injected_total: resp.injected_total,
        stored: resp.stored,
        capacity: resp.capacity,
        intercept_enabled: resp.intercept_enabled,
        offline: false,
      }
      match m.selected {
        Some(id) => {
          let mut found = false
          let mut pending = false
          for s in resp.flows {
            if s.id == id {
              found = true
              pending = s.pending
              break
            }
          }
          let need_detail = match m.detail {
            None => true
            Some(d) => d.pending || d.id != id
          }
          if !found {
            (
              {
                ..m,
                selected: None,
                detail: None,
                pretty_req: "",
                pretty_upstream: "",
                pretty_resp: "",
              },
              @rabbita.none,
            )
          } else if pending || need_detail {
            (m, fetch_detail(emit, id))
          } else {
            (m, @rabbita.none)
          }
        }
        None => (m, @rabbita.none)
      }
    }
    FlowsLoaded(Err(_)) => ({ ..model, offline: true, }, @rabbita.none)
    DetailLoaded(Ok(d)) => {
      let pretty_req = pretty(
        d.request.body,
        header_value(d.request.headers, "content-type"),
      )
      let pretty_upstream = match d.upstream_request {
        Some(u) => pretty(u.body, "application/json")
        None => ""
      }
      let pretty_resp = match d.response {
        Some(r) => pretty(r.body, header_value(r.headers, "content-type"))
        None => ""
      }
      (
        { ..model, detail: Some(d), pretty_req, pretty_upstream, pretty_resp, },
        @rabbita.none,
      )
    }
    DetailLoaded(Err(_)) => (model, @rabbita.none)
    Select(id) =>
      (
        {
          ..model,
          selected: Some(id),
          tab: RequestTab,
          detail: None,
          pretty_req: "",
          pretty_upstream: "",
          pretty_resp: "",
        },
        fetch_detail(emit, id),
      )
    SetTab(t) => ({ ..model, tab: t, }, @rabbita.none)
    Filter(s) => ({ ..model, filter: s, }, @rabbita.none)
    TogglePause => ({ ..model, paused: !model.paused, }, @rabbita.none)
    Clear =>
      (model, @rhttp.delete("/api/flows").expect_empty(_ => emit(Cleared)))
    Cleared =>
      (
        {
          ..model,
          flows: [],
          selected: None,
          detail: None,
          pretty_req: "",
          pretty_upstream: "",
          pretty_resp: "",
        },
        fetch_flows(emit),
      )
    ToggleIntercept => {
      let next : @shared.InterceptState = { enabled: !model.intercept_enabled, }
      (
        model,
        @rhttp.put("/api/intercept")
        .with_json(next)
        .expect_empty(_ => emit(InterceptToggled)),
      )
    }
    InterceptToggled => (model, fetch_flows(emit))
  }
}

///|
/// Poll the flow list every 1.5s unless paused.
fn subscriptions(model : Model, emit : @rabbita.Emit[Msg]) -> @sub.Sub {
  if model.paused {
    @sub.none
  } else {
    @sub.every(1500, emit(Tick))
  }
}

///|
fn main {
  // The builder runs at mount time, when the command runtime is ready;
  // creating the state earlier would drop the init command.
  let app = @rabbita.new(() => {
    let (state, emit) = @rabbita.create_state_with_init(
      init=emit => (initial_model(), fetch_flows(emit)),
      update~,
      subscriptions~,
    )
    state.view(model => view(model, emit))
  })
  app.mount("app")
}
