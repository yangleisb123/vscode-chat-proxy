///|
/// Max bytes stored per body (request or response) in the monitor.
pub let body_capture_limit : Int32 = 256 * 1024

///|
/// Default number of flows kept in the SQLite store.
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
  mut status : Int32
  mut reason : String
  mut response_headers : Array[(String, String)]
  mut response_body : Bytes
  mut response_size : Int32
  mut response_truncated : Bool
  mut end_ms : UInt64
  mut error : String?
  mut finished : Bool
  /// Whether the full flow has been written to the SQLite database. Finished
  /// flows release their captured bodies from memory; details are read back
  /// from the database on demand.
  mut persisted : Bool
}

///|
/// SQLite-backed flow store. One `monitor.sqlite` file lives in the system
/// temp directory (see `default_store_dir`); `FlowStore::new` opens an
/// in-memory database for tests.
///
/// The store is bounded: after every insert/update at most `capacity` rows are
/// kept (`DELETE` oldest + `auto_vacuum`). Only in-flight flows keep bodies in
/// memory; finished rows are read back from SQLite.
pub struct FlowStore {
  db : @sqlite.SqliteDriver
  dir : String
  capacity : Int32
  mut active : Array[Flow]
  mut next_id : Int32
  mut total : Int32
  mut injected_total : Int32
}

///|
/// Schema + SQLite tuning. `auto_vacuum` is set before the tables so deleted
/// rows return their pages to the filesystem; WAL keeps writes cheap while the
/// process runs.
let schema_sql : String = "PRAGMA journal_mode=WAL;\n" +
  "PRAGMA synchronous=NORMAL;\n" +
  "PRAGMA auto_vacuum=FULL;\n" +
  "PRAGMA busy_timeout=3000;\n" +
  "CREATE TABLE IF NOT EXISTS flows (\n" +
  "  id INTEGER PRIMARY KEY,\n" +
  "  start_ms INTEGER NOT NULL,\n" +
  "  client_addr TEXT NOT NULL,\n" +
  "  method TEXT NOT NULL,\n" +
  "  target TEXT NOT NULL,\n" +
  "  request_headers TEXT NOT NULL,\n" +
  "  request_body BLOB NOT NULL,\n" +
  "  request_size INTEGER NOT NULL,\n" +
  "  request_truncated INTEGER NOT NULL,\n" +
  "  intercepted INTEGER NOT NULL,\n" +
  "  upstream TEXT NOT NULL,\n" +
  "  injected INTEGER NOT NULL,\n" +
  "  upstream_body BLOB,\n" +
  "  upstream_truncated INTEGER NOT NULL,\n" +
  "  status INTEGER NOT NULL,\n" +
  "  reason TEXT NOT NULL,\n" +
  "  response_headers TEXT NOT NULL,\n" +
  "  response_body BLOB NOT NULL,\n" +
  "  response_size INTEGER NOT NULL,\n" +
  "  response_truncated INTEGER NOT NULL,\n" +
  "  end_ms INTEGER NOT NULL,\n" +
  "  error TEXT,\n" +
  "  finished INTEGER NOT NULL,\n" +
  "  content_type TEXT NOT NULL\n" +
  ");\n" +
  "CREATE INDEX IF NOT EXISTS idx_flows_id ON flows(id DESC);\n" +
  "CREATE TABLE IF NOT EXISTS stats (key TEXT PRIMARY KEY, value INTEGER NOT NULL);\n" +
  "INSERT OR IGNORE INTO stats (key, value) VALUES ('total', 0);\n" +
  "INSERT OR IGNORE INTO stats (key, value) VALUES ('injected_total', 0);\n"

///|
/// Default on-disk location for monitor data: a stable subdirectory of the
/// system temp directory, one per monitor port so separate proxy instances do
/// not overwrite each other's database.
///
/// `MONITOR_DIR` / `VSCODE_CHAT_PROXY_MONITOR_DIR` override the location.
/// The OS may clean the temp directory at any time; losing this file only
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
/// Directory currently backing this store; empty means the in-memory store.
pub fn FlowStore::data_dir(self : FlowStore) -> String {
  self.dir
}

///|
/// Open a SQLite database at `path` (or `:memory:`) and prepare the schema.
/// Returns `None` when the database cannot be opened/initialised, so callers
/// can fall back to an in-memory store instead of taking the proxy down.
fn open_store(path : String, dir : String, capacity : Int32) -> FlowStore? {
  let db = @sqlite.SqliteDriver::open(path) catch {
    e => {
      println("[monitor] cannot open " + path + ": " + e.to_string())
      return None
    }
  }
  let store : FlowStore = {
    db,
    dir,
    capacity,
    active: [],
    next_id: 1,
    total: 0,
    injected_total: 0,
  }
  if !store.init_schema() {
    store.db.close()
    return None
  }
  store.load_meta()
  store.mark_stale_pending()
  store.evict()
  Some(store)
}

///|
fn FlowStore::init_schema(self : FlowStore) -> Bool {
  try {
    self.db.exec_script(schema_sql)
    true
  } catch {
    e => {
      println("[monitor] cannot initialise SQLite schema: " + e.to_string())
      false
    }
  }
}

///|
/// Counters survive restarts; `next_id` continues after the largest stored id.
fn FlowStore::load_meta(self : FlowStore) -> Unit {
  self.total = self.read_stat("total")
  self.injected_total = self.read_stat("injected_total")
  let rows = self.rows("SELECT COALESCE(MAX(id), 0) + 1 FROM flows", [])
  if rows.length() > 0 {
    self.next_id = row_int(rows[0], 0)
  } else {
    self.next_id = 1
  }
}

///|
/// A previous process may have died between INSERT (begin) and UPDATE
/// (finish). Do not show such rows as eternally "pending".
fn FlowStore::mark_stale_pending(self : FlowStore) -> Unit {
  self.exec(
    "UPDATE flows SET finished = 1, " +
    "error = COALESCE(error, 'proxy stopped before flow completed'), " +
    "end_ms = start_ms WHERE finished = 0",
  )
  |> ignore
}

///|
fn FlowStore::read_stat(self : FlowStore, key : String) -> Int32 {
  let rows = self.rows("SELECT value FROM stats WHERE key = ?", [
    @moondb.Text(key),
  ])
  if rows.length() > 0 {
    row_int(rows[0], 0)
  } else {
    0
  }
}

///|
/// Execute one statement, logging (but not raising) SQLite errors.
fn FlowStore::exec(self : FlowStore, sql : String) -> Bool {
  try {
    self.db.execute(sql, []) |> ignore
    true
  } catch {
    e => {
      println("[monitor] sqlite exec failed: " + e.to_string())
      false
    }
  }
}

///|
fn FlowStore::rows(
  self : FlowStore,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] {
  self.db.query(sql, params) catch {
    e => {
      println("[monitor] sqlite query failed: " + e.to_string())
      []
    }
  }
}

///|
/// Open (or create) the monitor directory and its SQLite database. I/O
/// failures degrade gracefully to an in-memory store so the proxy itself is
/// never taken down by the monitor.
pub async fn FlowStore::open(
  dir : String,
  capacity~ : Int32 = default_flow_capacity,
) -> FlowStore {
  if dir.is_empty() {
    return FlowStore::new(capacity~)
  }
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    e =>
      println("[monitor] cannot create data dir " + dir + ": " + e.to_string())
  }
  let path = dir + "/monitor.sqlite"
  match open_store(path, dir, capacity) {
    Some(store) => {
      // The database and its WAL/SHM companions all carry captured API keys.
      for suffix in ["", "-wal", "-shm"] {
        @fs.chmod(path + suffix, 0o600) catch {
          _ => ()
        }
      }
      store
    }
    None => {
      println("[monitor] cannot use " + path + ", falling back to memory")
      FlowStore::new(capacity~)
    }
  }
}

///|
/// In-memory store (tests, and the fallback when the temp directory is not
/// writable). Same schema and SQL as the file-backed store.
pub fn FlowStore::new(capacity~ : Int32 = default_flow_capacity) -> FlowStore {
  match open_store(":memory:", "", capacity) {
    Some(store) => store
    None => panic()
  }
}

///|
/// Close the underlying database (mainly for tests and orderly shutdown).
pub fn FlowStore::close(self : FlowStore) -> Unit {
  self.db.close()
}

///|
/// Register a new flow (request fully read, response pending). The row is
/// inserted immediately so a crash leaves a visible (stale) record.
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
    persisted: false,
  }
  self.next_id += 1
  self.total += 1
  let values : Array[@moondb.Value] = [
    @moondb.Int(flow.id),
    @moondb.Int64(flow.start_ms.reinterpret_as_int64()),
    @moondb.Text(flow.client_addr),
    @moondb.Text(flow.http_method),
    @moondb.Text(flow.target),
    @moondb.Text(headers_to_text(flow.request_headers)),
    @moondb.Blob(flow.request_body),
    @moondb.Int(flow.request_size),
    @moondb.Int(bool_int(flow.request_truncated)),
    @moondb.Int(bool_int(flow.intercepted)),
    @moondb.Text(flow.upstream),
    @moondb.Int(0),
    @moondb.Null,
    @moondb.Int(0),
    @moondb.Int(0),
    @moondb.Text(""),
    @moondb.Text(""),
    @moondb.Blob(@utf8.encode("")),
    @moondb.Int(0),
    @moondb.Int(0),
    @moondb.Int64(0L),
    @moondb.Null,
    @moondb.Int(0),
    @moondb.Text(""),
  ]
  try self.db.execute(insert_flow_sql, values) |> ignore catch {
    e =>
      println(
        "[monitor] cannot insert flow #" +
        flow.id.to_string() +
        ": " +
        e.to_string(),
      )
  }
  self.exec("UPDATE stats SET value = value + 1 WHERE key = 'total'") |> ignore
  self.active.push(flow)
  self.evict()
  flow
}

///|
/// Mark a flow complete (idempotent), update its row and release bodies.
pub fn FlowStore::finish(self : FlowStore, flow : Flow) -> Unit {
  if flow.finished {
    return
  }
  flow.finished = true
  flow.end_ms = @env.now()
  if !self.take_active(flow.id) {
    // Cleared or evicted while the request was still in flight.
    return
  }
  if flow.injected {
    self.injected_total += 1
    self.exec("UPDATE stats SET value = value + 1 WHERE key = 'injected_total'")
    |> ignore
  }
  let values : Array[@moondb.Value] = [
    @moondb.Int(bool_int(flow.injected)),
    match flow.upstream_body {
      Some(body) => @moondb.Blob(body)
      None => @moondb.Null
    },
    @moondb.Int(bool_int(flow.upstream_truncated)),
    @moondb.Int(flow.status),
    @moondb.Text(flow.reason),
    @moondb.Text(headers_to_text(flow.response_headers)),
    @moondb.Blob(flow.response_body),
    @moondb.Int(flow.response_size),
    @moondb.Int(bool_int(flow.response_truncated)),
    @moondb.Int64(flow.end_ms.reinterpret_as_int64()),
    match flow.error {
      Some(msg) => @moondb.Text(msg)
      None => @moondb.Null
    },
    @moondb.Text(content_type(flow.response_headers)),
    @moondb.Int(flow.id),
  ]
  let changed = try
    self.db.execute(update_flow_sql, values).rows_affected > 0L
  catch {
    e => {
      println(
        "[monitor] cannot update flow #" +
        flow.id.to_string() +
        ": " +
        e.to_string(),
      )
      false
    }
  }
  if changed {
    flow.persisted = true
    // SQLite is now the source of truth for bodies.
    flow.request_body = @utf8.encode("")
    flow.upstream_body = None
    flow.response_body = @utf8.encode("")
  }
  self.evict()
}

///|
fn FlowStore::take_active(self : FlowStore, id : Int32) -> Bool {
  let mut i = 0
  while i < self.active.length() {
    if self.active[i].id == id {
      self.active.remove(i) |> ignore
      return true
    }
    i += 1
  }
  false
}

///|
/// Keep only the newest `capacity` rows. `auto_vacuum` reclaims the pages.
fn FlowStore::evict(self : FlowStore) -> Unit {
  if self.capacity <= 0 {
    return
  }
  self.exec(
    "DELETE FROM flows WHERE id NOT IN " +
    "(SELECT id FROM flows ORDER BY id DESC LIMIT " +
    self.capacity.to_string() +
    ")",
  )
  |> ignore
}

///|
/// Clear the list, the database rows and the counters.
pub fn FlowStore::clear(self : FlowStore) -> Unit {
  self.active = []
  self.total = 0
  self.injected_total = 0
  self.next_id = 1
  self.exec("DELETE FROM flows") |> ignore
  self.exec("UPDATE stats SET value = 0") |> ignore
  self.exec("VACUUM") |> ignore
}

///|
pub fn FlowStore::find(self : FlowStore, id : Int32) -> Flow? {
  for flow in self.active {
    if flow.id == id {
      return Some(flow)
    }
  }
  let rows = self.rows(find_flow_sql, [@moondb.Int(id)])
  if rows.length() == 0 {
    return None
  }
  let row = rows[0]
  let start_ms = row_int64(row, 0).reinterpret_as_uint64()
  let finished = row_int(row, 13) != 0
  let error = if row_is_null(row, 12) { None } else { Some(row_text(row, 12)) }
  Some({
    id,
    start_ms,
    client_addr: row_text(row, 1),
    http_method: row_text(row, 2),
    target: row_text(row, 3),
    request_headers: headers_from_text(row_text(row, 4)),
    request_size: row_int(row, 5),
    intercepted: row_int(row, 6) != 0,
    upstream: row_text(row, 7),
    request_body: @utf8.encode(""),
    request_truncated: row_int(row, 8) != 0,
    injected: row_int(row, 9) != 0,
    upstream_body: None,
    upstream_truncated: row_int(row, 10) != 0,
    status: row_int(row, 11),
    reason: row_text(row, 14),
    response_headers: headers_from_text(row_text(row, 15)),
    response_body: @utf8.encode(""),
    response_size: row_int(row, 16),
    response_truncated: row_int(row, 17) != 0,
    end_ms: row_int64(row, 18).reinterpret_as_uint64(),
    error,
    finished,
    persisted: finished,
  })
}

///|
/// Full detail of one flow: from memory while it is in flight, from SQLite
/// once it has been persisted.
pub fn FlowStore::detail(self : FlowStore, id : Int32) -> @shared.FlowDetail? {
  for flow in self.active {
    if flow.id == id {
      return Some(flow.detail())
    }
  }
  let rows = self.rows(detail_flow_sql, [@moondb.Int(id)])
  if rows.length() == 0 {
    return None
  }
  let row = rows[0]
  let start_ms = row_int64(row, 0).reinterpret_as_uint64()
  let end_ms = row_int64(row, 19).reinterpret_as_uint64()
  let finished = row_int(row, 21) != 0
  let error = if row_is_null(row, 20) { None } else { Some(row_text(row, 20)) }
  let status = row_int(row, 13)
  let reason = row_text(row, 14)
  let response_headers = headers_from_text(row_text(row, 15))
  let request : @shared.RequestData = {
    http_method: row_text(row, 2),
    target: row_text(row, 3),
    headers: headers_from_text(row_text(row, 4)),
    body: @utf8.decode_lossy(row_blob(row, 5)),
    truncated: row_int(row, 6) != 0,
    size: row_int(row, 7),
  }
  let upstream_request : @shared.UpstreamRequest? = if row_is_null(row, 11) {
    None
  } else {
    Some({
      body: @utf8.decode_lossy(row_blob(row, 11)),
      truncated: row_int(row, 12) != 0,
    })
  }
  let response : @shared.ResponseData? = if status == 0 && error is None {
    None
  } else {
    Some({
      status,
      reason,
      headers: response_headers,
      body: @utf8.decode_lossy(row_blob(row, 16)),
      truncated: row_int(row, 18) != 0,
      size: row_int(row, 17),
    })
  }
  Some({
    id,
    start_ms: start_ms.to_double(),
    duration_ms: duration_between(start_ms, end_ms),
    client_addr: row_text(row, 1),
    upstream: row_text(row, 9),
    intercepted: row_int(row, 8) != 0,
    injected: row_int(row, 10) != 0,
    pending: !finished,
    error,
    request,
    upstream_request,
    response,
  })
}

///|
/// Flow list API payload (newest first, shared contract type).
pub fn FlowStore::list_response(self : FlowStore) -> @shared.FlowsResponse {
  let rows = self.rows(
    "SELECT id, start_ms, method, target, status, reason, intercepted, " +
    "injected, finished, error, request_size, response_size, end_ms, " +
    "content_type FROM flows ORDER BY id DESC LIMIT " +
    self.capacity.to_string(),
    [],
  )
  let flows : Array[@shared.FlowSummary] = []
  for row in rows {
    let start_ms = row_int64(row, 1)
    let end_ms = row_int64(row, 12)
    let status = row_int(row, 4)
    let error = if row_is_null(row, 9) { None } else { Some(row_text(row, 9)) }
    flows.push({
      id: row_int(row, 0),
      start_ms: start_ms.to_double(),
      http_method: row_text(row, 2),
      path: row_text(row, 3),
      status,
      reason: row_text(row, 5),
      intercepted: row_int(row, 6) != 0,
      injected: row_int(row, 7) != 0,
      pending: row_int(row, 8) == 0,
      error,
      req_size: row_int(row, 10),
      resp_size: row_int(row, 11),
      duration_ms: duration_between(
        start_ms.reinterpret_as_uint64(),
        end_ms.reinterpret_as_uint64(),
      ),
      content_type: row_text(row, 13),
    })
  }
  {
    total: self.total,
    injected_total: self.injected_total,
    stored: flows.length(),
    capacity: self.capacity,
    flows,
  }
}

///|
fn row_int(row : @moondb.Row, index : Int32) -> Int32 {
  row.int(index) catch {
    _ => 0
  }
}

///|
fn row_int64(row : @moondb.Row, index : Int32) -> Int64 {
  row.int64(index) catch {
    _ => 0L
  }
}

///|
fn row_text(row : @moondb.Row, index : Int32) -> String {
  row.text(index) catch {
    _ => ""
  }
}

///|
fn row_blob(row : @moondb.Row, index : Int32) -> Bytes {
  row.blob(index) catch {
    _ => @utf8.encode("")
  }
}

///|
fn row_is_null(row : @moondb.Row, index : Int32) -> Bool {
  row.is_null(index) catch {
    _ => true
  }
}

///|
fn bool_int(value : Bool) -> Int32 {
  if value {
    1
  } else {
    0
  }
}

///|
fn duration_between(start_ms : UInt64, end_ms : UInt64) -> Int32 {
  if end_ms == 0UL || end_ms < start_ms {
    0
  } else {
    (end_ms - start_ms).to_int()
  }
}

///|
/// Serialize headers as `name: value\n` lines (HTTP header values cannot
/// contain newlines, so this round-trips safely).
fn headers_to_text(headers : Array[(String, String)]) -> String {
  let mut out = ""
  for pair in headers {
    out = out + pair.0 + ": " + pair.1 + "\n"
  }
  out
}

///|
fn headers_from_text(text : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for line in text.clamped_view().split("\n") {
    if !line.is_empty() {
      match line.split_once(": ") {
        Some((name, value)) => out.push((name.to_owned(), value.to_owned()))
        None => ()
      }
    }
  }
  out
}

///|
/// Insert statement used by `FlowStore::begin` (24 bound columns).
let insert_flow_sql : String = "INSERT INTO flows (" +
  "id, start_ms, client_addr, method, target, request_headers, " +
  "request_body, request_size, request_truncated, intercepted, upstream, " +
  "injected, upstream_body, upstream_truncated, status, reason, " +
  "response_headers, response_body, response_size, response_truncated, " +
  "end_ms, error, finished, content_type" +
  ") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"

///|
/// Update statement used by `FlowStore::finish` (12 fields + id).
let update_flow_sql : String = "UPDATE flows SET " +
  "injected = ?, upstream_body = ?, upstream_truncated = ?, status = ?, " +
  "reason = ?, response_headers = ?, response_body = ?, " +
  "response_size = ?, response_truncated = ?, end_ms = ?, error = ?, " +
  "finished = 1, content_type = ? WHERE id = ?"

///|
/// Full projection used by `FlowStore::detail`.
let detail_flow_sql : String = "SELECT " +
  "start_ms, client_addr, method, target, request_headers, request_body, " +
  "request_truncated, request_size, intercepted, upstream, injected, " +
  "upstream_body, upstream_truncated, status, reason, response_headers, " +
  "response_body, response_size, response_truncated, end_ms, error, " +
  "finished, content_type FROM flows WHERE id = ?"

///|
/// Metadata projection used by `FlowStore::find`.
let find_flow_sql : String = "SELECT " +
  "start_ms, client_addr, method, target, request_headers, request_size, " +
  "request_truncated, intercepted, upstream, injected, upstream_truncated, " +
  "status, error, finished, reason, response_headers, response_size, " +
  "response_truncated, end_ms FROM flows WHERE id = ?"

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
fn body_json(body : Bytes) -> String {
  @utf8.decode_lossy(body)
}

///|
fn duration_ms(flow : Flow) -> Int32 {
  duration_between(flow.start_ms, flow.end_ms)
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
