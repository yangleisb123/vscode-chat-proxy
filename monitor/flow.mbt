///|
/// Max bytes stored per body (request or response) in the monitor.
pub let body_capture_limit : Int32 = 256 * 1024

///|
/// Default number of flows kept in the ring buffer.
let default_flow_capacity : Int32 = 200

///|
/// One proxied request/response pair, as shown in the monitor UI.
pub(all) struct Flow {
  id : Int32
  start_ms : UInt64
  client_addr : String
  http_method : String
  target : String
  request_headers : Array[(String, String)]
  request_size : Int32
  intercepted : Bool
  upstream : String
  request_body : Bytes
  request_truncated : Bool
  mut injected : Bool
  mut upstream_body : Bytes?
  mut upstream_truncated : Bool
  mut status : Int32 // 0 = pending
  mut reason : String
  mut response_headers : Array[(String, String)]
  mut response_body : Bytes
  mut response_size : Int32
  mut response_truncated : Bool
  mut end_ms : UInt64
  mut error : String?
  mut finished : Bool
}

///|
/// In-memory ring buffer of recent flows. The async runtime is
/// single-threaded cooperative, so no locking is needed.
pub struct FlowStore {
  capacity : Int32
  mut flows : Array[Flow]
  mut next_id : Int32
  mut total : Int32
  mut injected_total : Int32
}

///|
pub fn FlowStore::new(capacity~ : Int32 = default_flow_capacity) -> FlowStore {
  { capacity, flows: [], next_id: 1, total: 0, injected_total: 0, }
}

///|
/// Store at most `body_capture_limit` bytes of a body.
pub fn cap_bytes(b : Bytes) -> (Bytes, Bool) {
  if b.length() <= body_capture_limit {
    (b, false)
  } else {
    (b.clamped_view(end=body_capture_limit).to_owned(), true)
  }
}

///|
/// Register a new flow (request fully read, response pending).
pub fn FlowStore::begin(
  self : FlowStore,
  client_addr~ : String,
  http_method~ : String,
  target~ : String,
  request_headers~ : Array[(String, String)],
  request_body~ : Bytes,
  intercepted~ : Bool,
  upstream~ : String,
) -> Flow {
  let (body, truncated) = cap_bytes(request_body)
  let flow : Flow = {
    id: self.next_id,
    start_ms: @env.now(),
    client_addr,
    http_method,
    target,
    request_headers,
    request_size: request_body.length(),
    intercepted,
    upstream,
    request_body: body,
    request_truncated: truncated,
    injected: false,
    upstream_body: None,
    upstream_truncated: false,
    status: 0,
    reason: "",
    response_headers: [],
    response_body: @utf8.encode(""),
    response_size: 0,
    response_truncated: false,
    end_ms: 0UL,
    error: None,
    finished: false,
  }
  self.next_id += 1
  self.total += 1
  self.flows.push(flow)
  if self.flows.length() > self.capacity {
    self.flows.remove(0) |> ignore
  }
  flow
}

///|
/// Mark a flow complete (idempotent).
pub fn FlowStore::finish(self : FlowStore, flow : Flow) -> Unit {
  if flow.finished {
    return
  }
  flow.finished = true
  flow.end_ms = @env.now()
  if flow.injected {
    self.injected_total += 1
  }
}

///|
pub fn FlowStore::clear(self : FlowStore) -> Unit {
  self.flows = []
  self.total = 0
  self.injected_total = 0
}

///|
pub fn FlowStore::find(self : FlowStore, id : Int32) -> Flow? {
  for flow in self.flows {
    if flow.id == id {
      return Some(flow)
    }
  }
  None
}

///|
fn body_json(body : Bytes) -> String {
  @utf8.decode_lossy(body)
}

///|
fn duration_ms(flow : Flow) -> Int32 {
  if flow.end_ms == 0UL {
    0
  } else {
    (flow.end_ms - flow.start_ms).to_int()
  }
}

///|
fn content_type(headers : Array[(String, String)]) -> String {
  for pair in headers {
    if pair.0.clamped_view().equal_ignore_ascii_case("content-type") {
      return pair.1
    }
  }
  ""
}

///|
/// Summary row for the flow list API (shared contract type).
pub fn Flow::summary(self : Flow) -> @shared.FlowSummary {
  {
    id: self.id,
    start_ms: self.start_ms.to_double(),
    http_method: self.http_method,
    path: self.target,
    status: self.status,
    reason: self.reason,
    intercepted: self.intercepted,
    injected: self.injected,
    pending: !self.finished,
    error: self.error,
    req_size: self.request_size,
    resp_size: self.response_size,
    duration_ms: duration_ms(self),
    content_type: content_type(self.response_headers),
  }
}

///|
/// Full detail for the flow detail API (shared contract type).
pub fn Flow::detail(self : Flow) -> @shared.FlowDetail {
  let request : @shared.RequestData = {
    http_method: self.http_method,
    target: self.target,
    headers: self.request_headers,
    body: body_json(self.request_body),
    truncated: self.request_truncated,
    size: self.request_size,
  }
  let upstream_request : @shared.UpstreamRequest? = match self.upstream_body {
    Some(b) => Some({ body: body_json(b), truncated: self.upstream_truncated, })
    None => None
  }
  let response : @shared.ResponseData? = if self.status == 0 &&
    self.error is None {
    None
  } else {
    Some({
      status: self.status,
      reason: self.reason,
      headers: self.response_headers,
      body: body_json(self.response_body),
      truncated: self.response_truncated,
      size: self.response_size,
    })
  }
  {
    id: self.id,
    start_ms: self.start_ms.to_double(),
    duration_ms: duration_ms(self),
    client_addr: self.client_addr,
    upstream: self.upstream,
    intercepted: self.intercepted,
    injected: self.injected,
    pending: !self.finished,
    error: self.error,
    request,
    upstream_request,
    response,
  }
}

///|
/// Flow list API payload (newest first, shared contract type).
pub fn FlowStore::list_response(self : FlowStore) -> @shared.FlowsResponse {
  let rows : Array[@shared.FlowSummary] = []
  let mut i = self.flows.length() - 1
  while i >= 0 {
    rows.push(self.flows[i].summary())
    i -= 1
  }
  {
    total: self.total,
    injected_total: self.injected_total,
    stored: self.flows.length(),
    capacity: self.capacity,
    flows: rows,
  }
}

///|
/// Best-effort decode of a complete chunked body (for display only;
/// the bytes forwarded to the client are never touched).
/// Falls back to the raw bytes when the input is not valid chunked framing.
pub fn decode_chunked_body(raw : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  let v = raw.clamped_view()
  let mut pos = 0
  for ;; {
    if pos >= v.length() {
      break
    }
    match v.clamped_view(start=pos).find(b"\r\n") {
      None => break
      Some(i) => {
        let line_end = pos + i
        let size_line = @utf8.decode_lossy(
          v.clamped_view(start=pos, end=line_end),
        )
        let size_part = match size_line.clamped_view().split_once(";") {
          Some((s, _)) => s
          None => size_line.clamped_view()
        }
        let size = @string.parse_int(size_part.trim(), radix=16) catch {
          _ => break
        }
        if size <= 0 {
          break
        }
        let data_start = line_end + 2
        if data_start + size > v.length() {
          // Truncated capture: keep whatever is available.
          out.write_bytes(v.clamped_view(start=data_start))
          break
        }
        out.write_bytes(v.clamped_view(start=data_start, end=data_start + size))
        pos = data_start + size + 2
      }
    }
  }
  if out.is_empty() && !raw.is_empty() {
    raw
  } else {
    out.to_bytes()
  }
}
