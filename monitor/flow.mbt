///|
/// Shared empty byte slice to avoid allocating `@utf8.encode("")` on hot paths.
let empty_bytes : Bytes = b""

///|
/// Max bytes stored per body (request or response) in the monitor.
pub let body_capture_limit : Int32 = 256 * 1024

///|
/// Default number of flows kept in the SQLite store.
let default_flow_capacity : Int32 = 200

///|
/// Background flusher interval in milliseconds. In-memory active/pending flows
/// are served directly by `list_response`/`detail`, so 50ms keeps UI latency
/// invisible while amortizing WAL writes and capping burst disk churn.
let flush_interval_ms : Int32 = 50

///|
/// One proxied request/response pair, as shown in the monitor UI.
pub(all) struct Flow {
  id : Int32
  start_ms : UInt64
  client_addr : String
  http_method : String
  target : String
  request_headers : Array[(String, String)]
  mut request_size : Int32
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
/// in-memory database for tests; `FlowStore::disabled` disables recording for
/// `--no-web` zero-overhead proxy runs.
///
/// The store is bounded: at most `capacity` rows are kept (`DELETE` oldest in
/// the same transaction + periodic `incremental_vacuum`). Only in-flight and
/// un-flushed flows keep bodies in memory; persisted summaries are cached in
/// memory so `GET /api/flows` never hits SQLite.
pub struct FlowStore {
  db : @sqlite.SqliteDriver
  dir : String
  capacity : Int32
  mut active : Array[Flow]
  mut pending : Array[Flow]
  mut next_id : Int32
  mut total : Int32
  mut injected_total : Int32
  mut intercept_enabled : Bool
  priv recording : Bool
  priv id_stride : Int32
  priv mut pending_total_delta : Int32
  priv mut pending_injected_delta : Int32
  priv mut db_count : Int32
  priv mut flush_ticks : Int32
  priv mut summary_cache : Array[@shared.FlowSummary]
  priv mut insert_stmt : &@moondb.Stmt?
  priv mut update_stat_stmt : &@moondb.Stmt?
  priv mut add_stat_stmt : &@moondb.Stmt?
  priv mut evict_stmt : &@moondb.Stmt?
  priv mut find_stmt : &@moondb.Stmt?
  priv mut detail_stmt : &@moondb.Stmt?
}

///|
/// Schema + SQLite tuning. Monitor history is best-effort temp data (losing it
/// on power loss never affects proxy correctness), so WAL + `synchronous=OFF` +
/// `auto_vacuum=INCREMENTAL` avoids per-flush fsync and page-relocation stalls.
/// `id INTEGER PRIMARY KEY` is already the ordered rowid B-tree, so no extra
/// secondary index on `id` is needed.
let schema_sql : String = "PRAGMA journal_mode=WAL;\n" +
  "PRAGMA synchronous=OFF;\n" +
  "PRAGMA temp_store=MEMORY;\n" +
  "PRAGMA cache_size=-4000;\n" +
  "PRAGMA auto_vacuum=INCREMENTAL;\n" +
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
  "DROP INDEX IF EXISTS idx_flows_id;\n" +
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
/// Live interception switch: when false the proxy forwards everything
/// unchanged (pure pass-through), ignoring the Chat Completions rule.
pub fn FlowStore::intercept_enabled(self : FlowStore) -> Bool {
  self.intercept_enabled
}

///|
/// Flip the interception switch at runtime (monitor UI / API). Initial value
/// comes from config; not persisted across restarts.
pub fn FlowStore::set_intercept_enabled(
  self : FlowStore,
  enabled : Bool,
) -> Unit {
  self.intercept_enabled = enabled
}

///|
/// Whether this store actually records flows (false for `FlowStore::disabled`,
/// used in `--no-web` mode so the proxy pays zero monitoring overhead).
pub fn FlowStore::is_recording(self : FlowStore) -> Bool {
  self.recording
}

///|
/// No-op flow store for `--no-web` mode: keeps the live `intercept_enabled`
/// flag without touching SQLite or buffering request/response bodies.
pub fn FlowStore::disabled() -> FlowStore {
  let db = @sqlite.SqliteDriver::open(":memory:") catch { _ => panic() }
  {
    db,
    dir: "",
    capacity: 0,
    active: [],
    pending: [],
    next_id: 1,
    total: 0,
    injected_total: 0,
    intercept_enabled: true,
    recording: false,
    id_stride: 1,
    pending_total_delta: 0,
    pending_injected_delta: 0,
    db_count: 0,
    flush_ticks: 0,
    summary_cache: [],
    insert_stmt: None,
    update_stat_stmt: None,
    add_stat_stmt: None,
    evict_stmt: None,
    find_stmt: None,
    detail_stmt: None,
  }
}

///|
/// Open a SQLite database at `path` (or `:memory:`) and prepare the schema.
/// Returns `None` when the database cannot be opened/initialised, so callers
/// can fall back to an in-memory store instead of taking the proxy down.
fn open_store(
  path : String,
  dir : String,
  capacity : Int32,
  worker_id : Int32,
  workers : Int32,
) -> FlowStore? {
  let db = @sqlite.SqliteDriver::open(path) catch {
    e => {
      println("[monitor] cannot open " + path + ": " + e.to_string())
      return None
    }
  }
  let stride = if workers > 1 { workers } else { 1 }
  let store : FlowStore = {
    db,
    dir,
    capacity,
    active: [],
    pending: [],
    next_id: 1,
    total: 0,
    injected_total: 0,
    intercept_enabled: true,
    recording: true,
    id_stride: stride,
    pending_total_delta: 0,
    pending_injected_delta: 0,
    db_count: 0,
    flush_ticks: 0,
    summary_cache: [],
    insert_stmt: None,
    update_stat_stmt: None,
    add_stat_stmt: None,
    evict_stmt: None,
    find_stmt: None,
    detail_stmt: None,
  }
  if !store.init_schema() {
    store.db.close()
    return None
  }
  store.prepare_statements()
  store.load_meta()
  if stride > 1 {
    // Disjoint ID lanes across worker processes: worker k gets ids congruent
    // to (k + 1) mod stride so concurrent WAL writers never collide on PK.
    let offset = if worker_id >= 0 { worker_id % stride } else { 0 }
    let base = store.next_id
    let rem = (base - 1) % stride
    let adjust = (offset - rem + stride) % stride
    store.next_id = base + adjust
  }
  if worker_id == 0 {
    store.mark_stale_pending()
    store.evict()
  }
  store.load_summary_cache()
  Some(store)
}

///|
fn FlowStore::prepare_statements(self : FlowStore) -> Unit {
  self.insert_stmt = Some(self.db.prepare(insert_flow_sql)) catch { _ => None }
  self.update_stat_stmt = Some(
    self.db.prepare("UPDATE stats SET value = ? WHERE key = ?"),
  ) catch {
    _ => None
  }
  self.add_stat_stmt = Some(
    self.db.prepare("UPDATE stats SET value = value + ? WHERE key = ?"),
  ) catch {
    _ => None
  }
  self.evict_stmt = Some(
    self.db.prepare(
      "DELETE FROM flows WHERE id IN (SELECT id FROM flows ORDER BY id ASC LIMIT ?)",
    ),
  ) catch {
    _ => None
  }
  self.find_stmt = Some(self.db.prepare(find_flow_sql)) catch { _ => None }
  self.detail_stmt = Some(self.db.prepare(detail_flow_sql)) catch { _ => None }
}

///|
fn FlowStore::close_statements(self : FlowStore) -> Unit {
  for
    s in [
      self.insert_stmt,
      self.update_stat_stmt,
      self.add_stat_stmt,
      self.evict_stmt,
      self.find_stmt,
      self.detail_stmt,
    ] {
    match s {
      Some(stmt) => stmt.close()
      None => ()
    }
  }
  self.insert_stmt = None
  self.update_stat_stmt = None
  self.add_stat_stmt = None
  self.evict_stmt = None
  self.find_stmt = None
  self.detail_stmt = None
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
  let rows = self.rows("SELECT COALESCE(MAX(id), 0) + 1, COUNT(*) FROM flows", [])
  if rows.length() > 0 {
    self.next_id = row_int(rows[0], 0)
    self.db_count = row_int(rows[0], 1)
  } else {
    self.next_id = 1
    self.db_count = 0
  }
}

///|
/// Populate the in-memory summary cache from persisted rows at startup.
fn FlowStore::load_summary_cache(self : FlowStore) -> Unit {
  let limit_clause = if self.capacity > 0 {
    " LIMIT " + self.capacity.to_string()
  } else {
    ""
  }
  let rows = self.rows(
    "SELECT id, start_ms, method, target, status, reason, intercepted, " +
    "injected, finished, error, request_size, response_size, end_ms, " +
    "content_type FROM flows ORDER BY id DESC" +
    limit_clause,
    [],
  )
  let out : Array[@shared.FlowSummary] = []
  for row in rows {
    let start_ms = row_int64(row, 1)
    let end_ms = row_int64(row, 12)
    let status = row_int(row, 4)
    let error = if row_is_null(row, 9) { None } else { Some(row_text(row, 9)) }
    out.push({
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
  self.summary_cache = out
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
  worker_id~ : Int32 = 0,
  workers~ : Int32 = 1,
) -> FlowStore {
  if dir.is_empty() {
    return FlowStore::new(capacity~)
  }
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    e =>
      println("[monitor] cannot create data dir " + dir + ": " + e.to_string())
  }
  let path = dir + "/monitor.sqlite"
  match open_store(path, dir, capacity, worker_id, workers) {
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
  match open_store(":memory:", "", capacity, 0, 1) {
    Some(store) => store
    None => panic()
  }
}

///|
/// Close the underlying database (mainly for tests and orderly shutdown).
pub fn FlowStore::close(self : FlowStore) -> Unit {
  self.flush_pending()
  self.close_statements()
  self.db.close()
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
  if !self.recording {
    return {
      id: 0,
      start_ms: 0UL,
      client_addr: "",
      http_method: "",
      target: "",
      request_headers: [],
      request_size: 0,
      intercepted: false,
      upstream: "",
      request_body: empty_bytes,
      request_truncated: false,
      injected: false,
      upstream_body: None,
      upstream_truncated: false,
      status: 0,
      reason: "",
      response_headers: [],
      response_body: empty_bytes,
      response_size: 0,
      response_truncated: false,
      end_ms: 0UL,
      error: None,
      finished: true,
      persisted: true,
    }
  }
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
    response_body: empty_bytes,
    response_size: 0,
    response_truncated: false,
    end_ms: 0UL,
    error: None,
    finished: false,
    persisted: false,
  }
  self.next_id += self.id_stride
  self.total += 1
  self.pending_total_delta += 1
  // Hot path: no SQL here. The row is batched to SQLite by the flusher.
  self.active.push(flow)
  flow
}

///|
/// Mark a flow complete (idempotent) and queue it for batched persistence.
pub fn FlowStore::finish(self : FlowStore, flow : Flow) -> Unit {
  if !self.recording || flow.finished {
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
    self.pending_injected_delta += 1
  }
  // Hot path: queue for batched persistence; bodies stay in memory until the
  // flusher writes them in a single transaction.
  self.pending.push(flow)
  // Guard memory under extreme bursts: if pending grows past 2x capacity before
  // the next flush tick, drop the oldest excess flows right away (they would be
  // evicted immediately on flush anyway).
  if self.capacity > 0 && self.pending.length() >= self.capacity * 2 {
    self.pending.sort_by((a, b) => a.id - b.id)
    let drop_n = self.pending.length() - self.capacity
    let kept : Array[Flow] = Array(capacity=self.capacity)
    for i = 0; i < drop_n; i = i + 1 {
      let old = self.pending[i]
      old.request_body = empty_bytes
      old.upstream_body = None
      old.response_body = empty_bytes
    }
    for i = drop_n; i < self.pending.length(); i = i + 1 {
      kept.push(self.pending[i])
    }
    self.pending = kept
  }
}

///|
fn FlowStore::insert_flow_row(self : FlowStore, flow : Flow) -> Unit {
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
    @moondb.Int(1),
    @moondb.Text(content_type(flow.response_headers)),
  ]
  try {
    match self.insert_stmt {
      Some(stmt) => {
        stmt.bind(values)
        stmt.execute() |> ignore
      }
      None => self.db.execute(insert_flow_sql, values) |> ignore
    }
  } catch {
    e =>
      println(
        "[monitor] cannot insert flow #" +
        flow.id.to_string() +
        ": " +
        e.to_string(),
      )
  }
}

///|
fn FlowStore::write_stat(self : FlowStore, key : String, value : Int32) -> Unit {
  try {
    match self.update_stat_stmt {
      Some(stmt) => {
        stmt.bind([@moondb.Int(value), @moondb.Text(key)])
        stmt.execute() |> ignore
      }
      None =>
        self.db.execute("UPDATE stats SET value = ? WHERE key = ?", [
          @moondb.Int(value),
          @moondb.Text(key),
        ])
        |> ignore
    }
  } catch {
    e => println("[monitor] sqlite stat update failed: " + e.to_string())
  }
}

///|
fn FlowStore::add_stat(self : FlowStore, key : String, delta : Int32) -> Unit {
  if delta == 0 {
    return
  }
  try {
    match self.add_stat_stmt {
      Some(stmt) => {
        stmt.bind([@moondb.Int(delta), @moondb.Text(key)])
        stmt.execute() |> ignore
      }
      None =>
        self.db.execute("UPDATE stats SET value = value + ? WHERE key = ?", [
          @moondb.Int(delta),
          @moondb.Text(key),
        ])
        |> ignore
    }
  } catch {
    e => println("[monitor] sqlite stat increment failed: " + e.to_string())
  }
}

///|
fn FlowStore::delete_oldest_rows(self : FlowStore, count : Int32) -> Int32 {
  if count <= 0 {
    return 0
  }
  try {
    let res = match self.evict_stmt {
      Some(stmt) => {
        stmt.bind([@moondb.Int(count)])
        stmt.execute()
      }
      None =>
        self.db.execute(
          "DELETE FROM flows WHERE id IN (SELECT id FROM flows ORDER BY id ASC LIMIT ?)",
          [@moondb.Int(count)],
        )
    }
    res.rows_affected.to_int()
  } catch {
    e => {
      println("[monitor] sqlite evict failed: " + e.to_string())
      0
    }
  }
}

///|
/// Write all surviving finished flows, update stats, and evict beyond capacity
/// in ONE single SQLite transaction (1 WAL commit, reusing prepared statements).
/// Flows that would be immediately evicted are discarded before touching SQLite.
pub fn FlowStore::flush_pending(self : FlowStore) -> Unit {
  if !self.recording || self.pending.length() == 0 {
    return
  }
  let batch = self.pending
  self.pending = []
  let keep = if self.capacity > 0 {
    let k = self.capacity - self.active.length()
    if k > 0 {
      k
    } else {
      0
    }
  } else {
    self.db_count + batch.length()
  }
  let mut skip = 0
  if self.capacity > 0 && batch.length() > keep {
    if keep > 0 {
      batch.sort_by((a, b) => a.id - b.id)
    }
    skip = batch.length() - keep
    for i = 0; i < skip; i = i + 1 {
      let dropped = batch[i]
      dropped.request_body = empty_bytes
      dropped.upstream_body = None
      dropped.response_body = empty_bytes
    }
  }
  let new_summaries : Array[@shared.FlowSummary] = Array(
    capacity=batch.length() - skip,
  )
  let mut deleted_any = false
  let began = try {
    self.db.begin()
    true
  } catch {
    e => {
      println("[monitor] sqlite begin failed: " + e.to_string())
      false
    }
  }
  for i = skip; i < batch.length(); i = i + 1 {
    let flow = batch[i]
    self.insert_flow_row(flow)
    self.db_count += 1
    if self.id_stride == 1 {
      new_summaries.push(flow.summary())
    }
    flow.persisted = true
    flow.request_body = empty_bytes
    flow.upstream_body = None
    flow.response_body = empty_bytes
  }
  if self.id_stride > 1 {
    let d_total = self.pending_total_delta
    let d_inj = self.pending_injected_delta
    self.pending_total_delta = 0
    self.pending_injected_delta = 0
    self.add_stat("total", d_total)
    self.add_stat("injected_total", d_inj)
    if self.capacity > 0 {
      let total_rows = match self.rows("SELECT COUNT(*) FROM flows", []) {
        [row] => row_int(row, 0)
        _ => self.db_count
      }
      if total_rows > keep {
        let removed = self.delete_oldest_rows(total_rows - keep)
        self.db_count = total_rows - removed
        deleted_any = removed > 0
      } else {
        self.db_count = total_rows
      }
    }
  } else {
    self.pending_total_delta = 0
    self.pending_injected_delta = 0
    self.write_stat("total", self.total)
    self.write_stat("injected_total", self.injected_total)
    if self.capacity > 0 && self.db_count > keep {
      if keep == 0 {
        self.exec("DELETE FROM flows") |> ignore
        self.db_count = 0
        self.summary_cache = []
        deleted_any = true
      } else {
        let over = self.db_count - keep
        let removed = self.delete_oldest_rows(over)
        self.db_count = if self.db_count > removed {
          self.db_count - removed
        } else {
          0
        }
        deleted_any = removed > 0
      }
    }
  }
  if began {
    self.db.commit() catch {
      e => println("[monitor] sqlite commit failed: " + e.to_string())
    }
  }
  if self.id_stride == 1 {
    if new_summaries.length() > 0 {
      for s in new_summaries {
        self.summary_cache.push(s)
      }
      self.summary_cache.sort_by((a, b) => b.id - a.id)
    }
    if self.capacity > 0 && self.summary_cache.length() > keep {
      self.summary_cache.truncate(keep)
    }
  }
  // Periodically reclaim free pages in incremental chunks so disk usage stays
  // bounded without relocating pages on every flush.
  if deleted_any && !self.dir.is_empty() {
    self.flush_ticks += 1
    if self.flush_ticks >= 32 {
      self.flush_ticks = 0
      self.exec("PRAGMA incremental_vacuum(64)") |> ignore
    }
  }
}

///|
/// Background flusher: batch-persist finished flows every ~50ms so the proxy
/// hot path never waits on SQLite and tail-latency spikes stay small.
pub async fn FlowStore::run_flusher(self : FlowStore) -> Unit {
  if !self.recording {
    return
  }
  for ;; {
    @async.sleep(flush_interval_ms)
    self.flush_pending()
  }
}

///|
fn FlowStore::take_active(self : FlowStore, id : Int32) -> Bool {
  let len = self.active.length()
  let mut i = 0
  while i < len {
    if self.active[i].id == id {
      let last = len - 1
      if i != last {
        self.active[i] = self.active[last]
      }
      self.active.pop() |> ignore
      return true
    }
    i += 1
  }
  false
}

///|
/// Keep only the newest `capacity` flows across memory (active+pending) and
/// SQLite. In-flight (active) flows are never dropped; oldest pending then
/// oldest persisted rows are evicted first.
fn FlowStore::evict(self : FlowStore) -> Unit {
  if !self.recording || self.capacity <= 0 {
    return
  }
  let mut over = self.active.length() +
    self.pending.length() +
    self.db_count -
    self.capacity
  if over <= 0 {
    return
  }
  if self.pending.length() > 0 {
    let drop_p = if over < self.pending.length() {
      over
    } else {
      self.pending.length()
    }
    if drop_p == self.pending.length() {
      self.pending = []
    } else {
      let kept : Array[Flow] = Array(capacity=self.pending.length() - drop_p)
      for i = drop_p; i < self.pending.length(); i = i + 1 {
        kept.push(self.pending[i])
      }
      self.pending = kept
    }
    over -= drop_p
  }
  if over > 0 {
    let removed = self.delete_oldest_rows(over)
    self.db_count = if self.db_count > removed {
      self.db_count - removed
    } else {
      0
    }
    let keep = self.capacity - self.active.length() - self.pending.length()
    let keep = if keep > 0 { keep } else { 0 }
    if self.summary_cache.length() > keep {
      self.summary_cache.truncate(keep)
    }
  }
}

///|
/// Clear the list, the database rows and the counters.
pub fn FlowStore::clear(self : FlowStore) -> Unit {
  self.active = []
  self.pending = []
  self.summary_cache = []
  self.db_count = 0
  self.total = 0
  self.injected_total = 0
  self.next_id = 1
  if !self.recording {
    return
  }
  self.exec("DELETE FROM flows") |> ignore
  self.exec("UPDATE stats SET value = 0") |> ignore
  self.exec("VACUUM") |> ignore
}

///|
pub fn FlowStore::find(self : FlowStore, id : Int32) -> Flow? {
  if !self.recording {
    return None
  }
  for flow in self.active {
    if flow.id == id {
      return Some(flow)
    }
  }
  for flow in self.pending {
    if flow.id == id {
      return Some(flow)
    }
  }
  let rows = match self.find_stmt {
    Some(stmt) =>
      try {
        stmt.bind([@moondb.Int(id)])
        stmt.query()
      } catch {
        e => {
          println("[monitor] sqlite find failed: " + e.to_string())
          []
        }
      }
    None => self.rows(find_flow_sql, [@moondb.Int(id)])
  }
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
    request_body: empty_bytes,
    request_truncated: row_int(row, 8) != 0,
    injected: row_int(row, 9) != 0,
    upstream_body: None,
    upstream_truncated: row_int(row, 10) != 0,
    status: row_int(row, 11),
    reason: row_text(row, 14),
    response_headers: headers_from_text(row_text(row, 15)),
    response_body: empty_bytes,
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
  if !self.recording {
    return None
  }
  for flow in self.active {
    if flow.id == id {
      return Some(flow.detail())
    }
  }
  for flow in self.pending {
    if flow.id == id {
      return Some(flow.detail())
    }
  }
  let rows = match self.detail_stmt {
    Some(stmt) =>
      try {
        stmt.bind([@moondb.Int(id)])
        stmt.query()
      } catch {
        e => {
          println("[monitor] sqlite detail failed: " + e.to_string())
          []
        }
      }
    None => self.rows(detail_flow_sql, [@moondb.Int(id)])
  }
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
/// Flow list API payload (newest first, shared contract type). In single-worker
/// mode this is served entirely from the in-memory summary cache + active/pending
/// queues (zero SQLite I/O); in multi-worker mode it reads the shared WAL DB so
/// the UI displays flows from all workers.
pub fn FlowStore::list_response(self : FlowStore) -> @shared.FlowsResponse {
  if self.id_stride > 1 && self.recording {
    self.load_summary_cache()
    self.total = self.read_stat("total") + self.pending_total_delta
    self.injected_total = self.read_stat("injected_total") +
      self.pending_injected_delta
  }
  let flows : Array[@shared.FlowSummary] = Array(
    capacity=self.summary_cache.length() +
      self.pending.length() +
      self.active.length(),
  )
  for s in self.summary_cache {
    flows.push(s)
  }
  // Include not-yet-persisted (pending) and in-flight (active) flows so the
  // list is complete even between flusher ticks.
  for flow in self.pending {
    flows.push(flow.summary())
  }
  for flow in self.active {
    flows.push(flow.summary())
  }
  flows.sort_by((a, b) => b.id - a.id)
  if self.capacity > 0 && flows.length() > self.capacity {
    flows.truncate(self.capacity)
  }
  {
    total: self.total,
    injected_total: self.injected_total,
    stored: flows.length(),
    capacity: self.capacity,
    intercept_enabled: self.intercept_enabled,
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
    _ => empty_bytes
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
  if headers.is_empty() {
    return ""
  }
  let sb = StringBuilder(capacity=256)
  for pair in headers {
    sb.write_string(pair.0)
    sb.write_string(": ")
    sb.write_string(pair.1)
    sb.write_char('\n')
  }
  sb.to_string()
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
