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
  mut request_body : Bytes
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
  /// Whether the full flow (headers and bodies) has been written to
  /// `<store dir>/<id>.json`. Persisted flows release their captured bodies
  /// from memory; details are read back from disk on demand.
  mut persisted : Bool
}

///|
/// Store of recent flows, newest last. When `dir` is non-empty every finished
/// flow is written to `<dir>/<zero-padded id>.json`; on startup the newest
/// `capacity` files are loaded back, so the monitor survives proxy restarts
/// while the OS keeps the temp directory around.
///
/// The store is deliberately bounded: at most `capacity` files are kept and
/// the oldest one is removed when a new flow pushes past the limit. Captured
/// bodies are dropped from memory once a flow has been persisted.
///
/// The async runtime is single-threaded cooperative, so no locking is needed.
pub struct FlowStore {
  dir : String
  capacity : Int32
  mut flows : Array[Flow]
  mut next_id : Int32
  mut total : Int32
  mut injected_total : Int32
}

///|
/// Memory-only store (used by tests and when `--no-web` disables the monitor).
pub fn FlowStore::new(capacity~ : Int32 = default_flow_capacity) -> FlowStore {
  { dir: "", capacity, flows: [], next_id: 1, total: 0, injected_total: 0, }
}

///|
/// Default on-disk location for monitor data: a stable subdirectory of the
/// system temp directory, one per monitor port so separate proxy instances do
/// not overwrite each other's files.
///
/// `MONITOR_DIR` / `VSCODE_CHAT_PROXY_MONITOR_DIR` override the location.
/// The OS may clean the temp directory at any time; losing these files only
/// loses monitor history, never proxy correctness.
pub fn default_store_dir(port~ : Int32) -> String {
  for name in ["VSCODE_CHAT_PROXY_MONITOR_DIR", "MONITOR_DIR"] {
    match @env.get_env_var(name) {
      Some(raw) => {
        let v = raw.trim()
        if !v.is_empty() {
          return v.to_owned()
        }
      }
      None => ()
    }
  }
  let mut base = "/tmp"
  for name in ["TMPDIR", "TEMP", "TMP"] {
    match @env.get_env_var(name) {
      Some(raw) => {
        let v = raw.trim()
        if !v.is_empty() {
          base = v.to_owned()
          break
        }
      }
      None => ()
    }
  }
  let base = base.trim_end(chars="/\\")
  let sep = if base.contains("\\") { "\\" } else { "/" }
  base.to_owned() + sep + "vscode-chat-proxy-monitor-" + port.to_string()
}

///|
/// Directory currently backing this store; empty means memory-only.
pub fn FlowStore::data_dir(self : FlowStore) -> String {
  self.dir
}

///|
/// Absolute path of the JSON file for flow `id`.
fn FlowStore::flow_path(self : FlowStore, id : Int32) -> String {
  self.dir + "/" + id.to_string().pad_start(10, '0') + ".json"
}

///|
/// Open (or create) the monitor directory and load the newest `capacity`
/// flow files. I/O failures degrade gracefully to a memory-only store so the
/// proxy itself is never taken down by the monitor.
pub async fn FlowStore::open(
  dir : String,
  capacity~ : Int32 = default_flow_capacity,
) -> FlowStore {
  let store : FlowStore = {
    dir,
    capacity,
    flows: [],
    next_id: 1,
    total: 0,
    injected_total: 0,
  }
  if dir.is_empty() {
    return store
  }
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    e => {
      println("[monitor] cannot create data dir " + dir + ": " + e.to_string())
      return { ..store, dir: "", }
    }
  }
  let names = @fs.readdir(dir, sort=true) catch { _ => [] }
  let files : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      files.push(name)
    }
  }
  let mut first_kept = 0
  if files.length() > capacity {
    first_kept = files.length() - capacity
  }
  let mut max_id = 0
  let mut index = 0
  for name in files {
    let path = dir + "/" + name
    if index < first_kept {
      // More files than the configured capacity (e.g. after a restart with a
      // smaller limit): drop the oldest ones.
      @fs.remove(path, allow_missing=true) catch {
        _ => ()
      }
    } else {
      let detail = try {
        let text = @fs.read_file(path).text()
        let d : @shared.FlowDetail = @json.from_json(@json.parse(text))
        Some(d)
      } catch {
        _ => None
      }
      match detail {
        Some(d) => {
          store.flows.push(flow_from_detail(d))
          store.total += 1
          if d.injected {
            store.injected_total += 1
          }
          if d.id > max_id {
            max_id = d.id
          }
        }
        None => ()
      }
    }
    index += 1
  }
  store.next_id = max_id + 1
  store
}

///|
/// Rebuild the in-memory (metadata-only) form of a persisted flow. Bodies are
/// intentionally left empty: `FlowStore::detail` reads them from the JSON file.
fn flow_from_detail(d : @shared.FlowDetail) -> Flow {
  let response = d.response
  let status = match response {
    Some(r) => r.status
    None => 0
  }
  let reason = match response {
    Some(r) => r.reason
    None => ""
  }
  let response_headers : Array[(String, String)] = match response {
    Some(r) => r.headers
    None => []
  }
  let response_size = match response {
    Some(r) => r.size
    None => 0
  }
  let response_truncated = match response {
    Some(r) => r.truncated
    None => false
  }
  let start_ms = d.start_ms.to_uint64()
  {
    id: d.id,
    start_ms,
    client_addr: d.client_addr,
    http_method: d.request.http_method,
    target: d.request.target,
    request_headers: d.request.headers,
    request_size: d.request.size,
    intercepted: d.intercepted,
    upstream: d.upstream,
    request_body: @utf8.encode(""),
    request_truncated: d.request.truncated,
    injected: d.injected,
    upstream_body: None,
    upstream_truncated: false,
    status,
    reason,
    response_headers,
    response_body: @utf8.encode(""),
    response_size,
    response_truncated,
    end_ms: start_ms + d.duration_ms.to_uint64(),
    error: d.error,
    finished: true,
    persisted: true,
  }
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
pub async fn FlowStore::begin(
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
    persisted: false,
  }
  self.next_id += 1
  self.total += 1
  self.flows.push(flow)
  if self.flows.length() > self.capacity {
    let evicted = self.flows.remove(0)
    if evicted.persisted && !self.dir.is_empty() {
      @fs.remove(self.flow_path(evicted.id), allow_missing=true) catch {
        e => println("[monitor] cannot remove old flow file: " + e.to_string())
      }
    }
  }
  flow
}

///|
/// Mark a flow complete (idempotent), write it to disk when the store has a
/// directory, and release its captured bodies from memory afterwards.
pub async fn FlowStore::finish(self : FlowStore, flow : Flow) -> Unit {
  if flow.finished {
    return
  }
  flow.finished = true
  flow.end_ms = @env.now()
  // Cleared or evicted while the request was still in flight: nothing to show.
  if !self.contains(flow) {
    return
  }
  if flow.injected {
    self.injected_total += 1
  }
  if self.dir.is_empty() {
    return
  }
  try {
    let json = flow.detail().to_json().stringify()
    @fs.write_file(self.flow_path(flow.id), json, permission=0o600)
    flow.persisted = true
    // The JSON file is now the source of truth for bodies.
    flow.request_body = @utf8.encode("")
    flow.upstream_body = None
    flow.response_body = @utf8.encode("")
  } catch {
    e =>
      println(
        "[monitor] cannot persist flow #" +
        flow.id.to_string() +
        ": " +
        e.to_string(),
      )
  }
}

///|
/// Clear the list and delete every flow file in the store directory.
pub async fn FlowStore::clear(self : FlowStore) -> Unit {
  self.flows = []
  self.total = 0
  self.injected_total = 0
  if self.dir.is_empty() {
    return
  }
  let names = @fs.readdir(self.dir) catch { _ => [] }
  for name in names {
    if name.has_suffix(".json") {
      @fs.remove(self.dir + "/" + name, allow_missing=true) catch {
        _ => ()
      }
    }
  }
}

///|
/// Whether `flow` is still part of this store (it may have been evicted or
/// cleared while the request was in flight).
fn FlowStore::contains(self : FlowStore, flow : Flow) -> Bool {
  match self.find(flow.id) {
    Some(f) => f.id == flow.id
    None => false
  }
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
/// Full detail of one flow: from memory while it is in flight, from its JSON
/// file once it has been persisted.
pub async fn FlowStore::detail(
  self : FlowStore,
  id : Int32,
) -> @shared.FlowDetail? {
  match self.find(id) {
    None => None
    Some(flow) =>
      if flow.persisted && !self.dir.is_empty() {
        let detail = try {
          let text = @fs.read_file(self.flow_path(id)).text()
          let d : @shared.FlowDetail = @json.from_json(@json.parse(text))
          Some(d)
        } catch {
          e => {
            println(
              "[monitor] cannot read flow #" +
              id.to_string() +
              ": " +
              e.to_string(),
            )
            None
          }
        }
        match detail {
          Some(d) => Some(d)
          None => Some(flow.detail())
        }
      } else {
        Some(flow.detail())
      }
  }
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
