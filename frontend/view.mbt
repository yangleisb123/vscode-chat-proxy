///|
/// Rendering of the monitor UI (rabbita html combinators).

///|
/// Cached Intl.DateTimeFormat avoids creating a fresh formatter 200x per 1.5s tick.
extern "js" fn locale_time(ms : Double) -> String =
  #|(() => {
  #|  const fmt = new Intl.DateTimeFormat("zh-CN", {
  #|    hour12: false,
  #|    hour: "2-digit",
  #|    minute: "2-digit",
  #|    second: "2-digit",
  #|  });
  #|  return (ms) => fmt.format(ms);
  #|})()

///|
fn fmt_size(n : Int32) -> String {
  if n < 1024 {
    "\{n} B"
  } else if n < 1048576 {
    let t = n * 10 / 1024
    "\{t / 10}.\{t % 10} K"
  } else {
    let h = n * 100 / 1048576
    let frac = h % 100
    let frac_str = if frac < 10 { "0\{frac}" } else { "\{frac}" }
    "\{h / 100}.\{frac_str} M"
  }
}

///|
fn header_value(headers : Array[(String, String)], name : String) -> String {
  for pair in headers {
    if pair.0.clamped_view().equal_ignore_ascii_case(name) {
      return pair.1
    }
  }
  ""
}

///|
fn pretty(body : String, content_type : String) -> String {
  if body == "" {
    return "（空）"
  }
  let trimmed = body.clamped_view().trim_start()
  let looks_json = content_type.clamped_view().to_lower().contains("json") ||
    trimmed.has_prefix("{") ||
    trimmed.has_prefix("[")
  if looks_json {
    let j = @json.parse(body) catch { _ => return body }
    return j.stringify(indent=2)
  }
  body
}

///|
fn stats_text(model : Model) -> String {
  if model.offline {
    "无法连接代理监控端口…"
  } else {
    "共 \{model.total} 条 · 已注入 \{model.injected_total} · 缓存 \{model.stored}/\{model.capacity}"
  }
}

///|
fn filtered_flows(model : Model) -> Array[@shared.FlowSummary] {
  let q = model.filter.clamped_view().trim().to_lower()
  if q.is_empty() {
    return model.flows
  }
  let out : Array[@shared.FlowSummary] = []
  for f in model.flows {
    if f.path.clamped_view().to_lower().contains(q) ||
      f.http_method.clamped_view().to_lower().contains(q) {
      out.push(f)
    }
  }
  out
}

///|
fn view(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.fragment([
    @html.header([
      @html.h1([
        @html.text("vscode-chat-proxy "),
        @html.span([@html.text("请求监控")]),
      ]),
      @html.div(id="stats", [@html.text(stats_text(model))]),
      @html.input(
        input_type=Text,
        id="filter",
        placeholder="过滤 path / method…",
        value=model.filter,
        on_input=s => emit(Filter(s)),
      ),
      @html.button(
        class=if model.intercept_enabled { "on" } else { "" },
        on_click=emit(ToggleIntercept),
        [
          @html.text(
            if model.intercept_enabled {
              "拦截:开"
            } else {
              "拦截:关"
            },
          ),
        ],
      ),
      @html.button(
        class=if model.paused { "on" } else { "" },
        on_click=emit(TogglePause),
        [@html.text(if model.paused { "继续" } else { "暂停" })],
      ),
      @html.button(on_click=emit(Clear), [@html.text("清空")]),
    ]),
    @html.main_([
      @html.div(id="list", [
        @html.table(class="flows", [
          @html.thead([
            @html.tr([
              @html.th([@html.text("#")]),
              @html.th([@html.text("时间")]),
              @html.th([@html.text("方法")]),
              @html.th([@html.text("路径")]),
              @html.th([@html.text("状态")]),
              @html.th([@html.text("标记")]),
              @html.th([@html.text("大小 入/出")]),
              @html.th([@html.text("耗时")]),
            ]),
          ]),
          @html.tbody(
            [
              for f in filtered_flows(model) => flow_row(f, model, emit)
            ],
          ),
        ]),
      ]),
      @html.div(id="detail", [detail_view(model, emit)]),
    ]),
  ])
}

///|
fn flow_row(
  f : @shared.FlowSummary,
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let mut cls = if model.selected == Some(f.id) { "sel" } else { "" }
  if f.error is Some(_) {
    cls = cls + " err"
  }
  let st_cls = if f.pending {
    "st-pending"
  } else if f.status >= 400 || f.error is Some(_) {
    "st-bad"
  } else if f.status >= 200 && f.status < 300 {
    "st-good"
  } else {
    ""
  }
  let mark = (if f.injected { "已注入 " } else { "" }) +
    (if f.intercepted { "拦截" } else { "" })
  @html.tr(
    class=cls,
    attrs=@html.Attrs::build().on_click(_ => emit(Select(f.id))),
    [
      @html.td([@html.text("#\{f.id}")]),
      @html.td([@html.text(locale_time(f.start_ms))]),
      @html.td([@html.text(f.http_method)]),
      @html.td(class="path", [@html.text(f.path)]),
      @html.td(class=st_cls, [
        @html.text(if f.pending { "…" } else { f.status.to_string() }),
      ]),
      @html.td(class=if f.injected { "inj" } else { "" }, [@html.text(mark)]),
      @html.td([
        @html.text(fmt_size(f.req_size) + " / " + fmt_size(f.resp_size)),
      ]),
      @html.td([@html.text(if f.pending { "" } else { "\{f.duration_ms} ms" })]),
    ],
  )
}

///|
fn tab_button(
  label : String,
  tab : Tab,
  current : Tab,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.button(
    class=if current == tab { "on" } else { "" },
    on_click=emit(SetTab(tab)),
    [@html.text(label)],
  )
}

///|
fn meta_text(d : @shared.FlowDetail) -> String {
  (if d.pending { "进行中" } else { "\{d.duration_ms} ms" }) +
  " · 客户端 \{d.client_addr} · 上游 \{d.upstream}" +
  (if d.injected { " · 已注入 system 前缀" } else { "" })
}

///|
fn detail_view(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.detail {
    None =>
      @html.div(class="empty", [
        @html.text("点击左侧请求查看入参 / 出参"),
      ])
    Some(d) =>
      @html.fragment([
        @html.div(class="dbar", [
          @html.span(class="dtitle", [
            @html.text("#\{d.id} \{d.request.http_method} \{d.request.target}"),
          ]),
          @html.span(class="dmeta", [@html.text(meta_text(d))]),
        ]),
        match d.error {
          Some(e) => @html.div(class="errbox", [@html.text("错误：\{e}")])
          None => @html.nothing
        },
        @html.div(class="tabs", [
          tab_button("请求（入参）", RequestTab, model.tab, emit),
          tab_button("响应（出参）", ResponseTab, model.tab, emit),
          if d.injected && d.upstream_request is Some(_) {
            tab_button("注入后转发体", InjectedTab, model.tab, emit)
          } else {
            @html.nothing
          },
        ]),
        pane(d, model),
      ])
  }
}

///|
fn pane(d : @shared.FlowDetail, model : Model) -> @html.Html {
  match model.tab {
    RequestTab => request_pane(d.request, model.pretty_req, d.request.truncated)
    InjectedTab =>
      match d.upstream_request {
        Some(u) => request_pane(d.request, model.pretty_upstream, u.truncated)
        None => @html.nothing
      }
    ResponseTab =>
      match d.response {
        None =>
          @html.div(class="empty", [
            @html.text(
              if d.pending {
                "等待上游响应…"
              } else {
                "无响应"
              },
            ),
          ])
        Some(r) =>
          @html.fragment([
            @html.div(class="line", [
              @html.text("HTTP/1.1 \{r.status} \{r.reason}"),
            ]),
            headers_table(r.headers),
            body_block(model.pretty_resp, r.truncated, r.size),
          ])
      }
  }
}

///|
fn request_pane(
  req : @shared.RequestData,
  formatted_body : String,
  truncated : Bool,
) -> @html.Html {
  @html.fragment([
    @html.div(class="line", [
      @html.text("\{req.http_method} \{req.target} HTTP/1.1"),
    ]),
    headers_table(req.headers),
    body_block(formatted_body, truncated, req.size),
  ])
}

///|
fn headers_table(headers : Array[(String, String)]) -> @html.Html {
  @html.table(class="hdrs", [
    @html.tbody(
      [
        for pair in headers => {
          @html.tr([
            @html.td(class="hk", [@html.text(pair.0)]),
            @html.td(class="hv", [@html.text(pair.1)]),
          ])
        }
      ],
    ),
  ])
}

///|
fn body_block(
  formatted_body : String,
  truncated : Bool,
  size : Int32,
) -> @html.Html {
  @html.fragment([
    @html.div(class="bnote", [
      @html.text(
        "Body（\{fmt_size(size)}）" +
        (if truncated { " · 已截断，仅保存前 256 KiB" } else { "" }),
      ),
    ]),
    @html.pre([@html.text(formatted_body)]),
  ])
}
