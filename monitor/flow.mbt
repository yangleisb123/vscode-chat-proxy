///|
/// Shared empty byte slice to avoid allocating `@utf8.encode("")` on hot paths.
let empty_bytes : Bytes = b""

///|
/// Max bytes stored per body (request or response) in the monitor.
pub let body_capture_limit : Int32 = 256 * 1024

///|
/// Default number of flows kept in the monitor store.
let default_flow_capacity : Int32 = 200

///|
/// Background flusher interval in milliseconds. Active and pending flows are
/// served directly from memory, so 100ms keeps UI latency invisible while
/// amortizing disk appends and capping burst I/O to at most `capacity` flows.
let flush_interval_ms : Int32 = 100

///|
/// 16-byte segment file header: `VCP1` (4B) + version=1 (4B LE) + gen (8B LE).
let seg_header_size : Int64 = 16L

///|
/// 8-byte record frame header: `FLW1` (4B) + payload_len (4B LE).
let rec_header_size : Int32 = 8

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
  /// Whether the full flow has been persisted to the append-only log. Finished
  /// flows release their captured bodies from memory; details are read back on
  /// demand via async `pread` (`File::read_exactly_at`).
  mut persisted : Bool
}

///|
/// In-memory index entry for one persisted flow. Keeps only the lightweight
/// summary plus the exact `(segment, offset, length)` location on disk (or
/// `mem_payload` in in-memory mode).
priv struct PersistedEntry {
  id : Int32
  seg : Int32
  payload_offset : Int64
  payload_len : Int32
  summary : @shared.FlowSummary
  mem_payload : Bytes?
}

///|
/// Decoded metadata header of a persisted flow record (everything before the
/// three raw body blobs).
priv struct DecodedMeta {
  id : Int32
  start_ms : UInt64
  end_ms : UInt64
  status : Int32
  request_size : Int32
  response_size : Int32
  total_snapshot : Int32
  injected_snapshot : Int32
  request_truncated : Bool
  intercepted : Bool
  injected : Bool
  upstream_truncated : Bool
  response_truncated : Bool
  finished : Bool
  has_upstream_body : Bool
  client_addr : String
  http_method : String
  target : String
  upstream : String
  reason : String
  content_type : String
  error : String?
  request_headers : Array[(String, String)]
  response_headers : Array[(String, String)]
}

///|
/// Async sequential append-only file store for captured flows.
///
/// Uses two rotating segment files (`flows.0.log` and `flows.1.log`) inside the
/// monitor directory so:
/// - Writes are batched into ONE sequential `@fs.File::write_at` call that runs
///   off the event loop in `moonbitlang/async`'s C worker thread pool (zero
///   event-loop stalls even on 64–256 KiB LLM request/response bodies).
/// - Disk usage is strictly bounded without compaction copies: once the active
///   segment holds `>= capacity` records and the inactive segment has no live
///   entries, the inactive segment is truncated and becomes active (1.0x write
///   amplification).
/// - `GET /api/flows` is served purely from memory; `GET /api/flows/:id` reads
///   only the requested record via a single async `File::read_exactly_at`.
/// - `FlowStore::new` keeps records in memory for unit tests;
///   `FlowStore::disabled` disables recording for `--no-web` zero-overhead runs.
pub struct FlowStore {
  dir : String
  capacity : Int32
  mut active : Array[Flow]
  mut pending : Array[Flow]
  mut next_id : Int32
  mut total : Int32
  mut injected_total : Int32
  mut intercept_enabled : Bool
  priv recording : Bool
  priv worker_id : Int32
  priv workers : Int32
  priv id_stride : Int32
  priv seg_files : FixedArray[@fs.File?]
  priv mut seg_offsets : FixedArray[Int64]
  priv mut seg_counts : FixedArray[Int32]
  priv mut active_seg : Int32
  priv mut gen : UInt64
  priv mut persisted : Array[PersistedEntry]
  priv mut flushing : Array[Flow]
  priv mut clear_epoch : Int32
  priv flush_sem : @async.Semaphore
}

///|
/// Default on-disk location for monitor data: a stable subdirectory of the
/// system temp directory, one per monitor port so separate proxy instances do
/// not overwrite each other's logs.
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
/// flag without writing files or buffering request/response bodies.
pub fn FlowStore::disabled() -> FlowStore {
  {
    dir: "",
    capacity: 0,
    active: [],
    pending: [],
    next_id: 1,
    total: 0,
    injected_total: 0,
    intercept_enabled: true,
    recording: false,
    worker_id: 0,
    workers: 1,
    id_stride: 1,
    seg_files: [None, None],
    seg_offsets: [0L, 0L],
    seg_counts: [0, 0],
    active_seg: 0,
    gen: 0UL,
    persisted: [],
    flushing: [],
    clear_epoch: 0,
    flush_sem: @async.Semaphore(1),
  }
}

///|
/// In-memory store (tests, and the fallback when the temp directory is not
/// writable). Uses the exact same binary record codec and eviction rules as
/// the file-backed store.
pub fn FlowStore::new(capacity~ : Int32 = default_flow_capacity) -> FlowStore {
  {
    dir: "",
    capacity,
    active: [],
    pending: [],
    next_id: 1,
    total: 0,
    injected_total: 0,
    intercept_enabled: true,
    recording: true,
    worker_id: 0,
    workers: 1,
    id_stride: 1,
    seg_files: [None, None],
    seg_offsets: [0L, 0L],
    seg_counts: [0, 0],
    active_seg: 0,
    gen: 0UL,
    persisted: [],
    flushing: [],
    clear_epoch: 0,
    flush_sem: @async.Semaphore(1),
  }
}

///|
fn segment_path_for(
  dir : String,
  worker_id : Int32,
  workers : Int32,
  seg : Int32,
) -> String {
  let sep = if dir.contains("\\") { "\\" } else { "/" }
  if workers > 1 {
    dir +
    sep +
    "flows-w" +
    worker_id.to_string() +
    "." +
    seg.to_string() +
    ".log"
  } else {
    dir + sep + "flows." + seg.to_string() + ".log"
  }
}

///|
fn FlowStore::seg_path(self : FlowStore, seg : Int32) -> String {
  segment_path_for(self.dir, self.worker_id, self.workers, seg)
}

///|
fn make_segment_header(gen : UInt64) -> Bytes {
  let buf = @buffer.Buffer(capacity=16)
  buf.write_bytesview(b"VCP1")
  buf.write_int_le(1)
  buf.write_uint64_le(gen)
  buf.to_bytes()
}

///|
fn read_u32_le(b : Bytes, pos : Int32) -> Int32 {
  let b0 = b[pos].to_int()
  let b1 = b[pos + 1].to_int()
  let b2 = b[pos + 2].to_int()
  let b3 = b[pos + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn read_u64_le(b : Bytes, pos : Int32) -> UInt64 {
  let lo = read_u32_le(b, pos).reinterpret_as_uint().to_uint64()
  let hi = read_u32_le(b, pos + 4).reinterpret_as_uint().to_uint64()
  lo | (hi << 32)
}

///|
fn check_magic(b : Bytes, pos : Int32, m : Bytes) -> Bool {
  pos + 4 <= b.length() &&
  b[pos] == m[0] &&
  b[pos + 1] == m[1] &&
  b[pos + 2] == m[2] &&
  b[pos + 3] == m[3]
}

///|
fn write_lp_string(buf : @buffer.Buffer, s : String) -> Unit {
  let utf8 = @utf8.encode(s)
  buf.write_int_le(utf8.length())
  if utf8.length() > 0 {
    buf.write_bytesview(utf8[:])
  }
}

///|
fn write_u32_le(out : FixedArray[Byte], pos : Int32, value : Int32) -> Unit {
  out[pos] = value.to_byte()
  out[pos + 1] = (value >> 8).to_byte()
  out[pos + 2] = (value >> 16).to_byte()
  out[pos + 3] = (value >> 24).to_byte()
}

///|
fn write_lp_bytes(out : FixedArray[Byte], pos : Int32, data : Bytes) -> Int32 {
  let len = data.length()
  write_u32_le(out, pos, len)
  out.blit_from_bytes(pos + 4, data, 0, len)
  pos + 4 + len
}

///|
fn write_headers_bin(
  buf : @buffer.Buffer,
  headers : Array[(String, String)],
) -> Unit {
  buf.write_int_le(headers.length())
  for pair in headers {
    write_lp_string(buf, pair.0)
    write_lp_string(buf, pair.1)
  }
}

///|
/// Encode one flow's metadata section (everything before the 3 raw body blobs).
fn encode_flow_meta(
  flow : Flow,
  total_snap : Int32,
  injected_snap : Int32,
) -> Bytes {
  let meta = @buffer.Buffer(capacity=512)
  meta.write_int_le(flow.id)
  meta.write_uint64_le(flow.start_ms)
  meta.write_uint64_le(flow.end_ms)
  meta.write_int_le(flow.status)
  meta.write_int_le(flow.request_size)
  meta.write_int_le(flow.response_size)
  meta.write_int_le(total_snap)
  meta.write_int_le(injected_snap)
  let mut flags = 0
  if flow.request_truncated {
    flags = flags | 1
  }
  if flow.intercepted {
    flags = flags | 2
  }
  if flow.injected {
    flags = flags | 4
  }
  if flow.upstream_truncated {
    flags = flags | 8
  }
  if flow.response_truncated {
    flags = flags | 16
  }
  if flow.finished {
    flags = flags | 32
  }
  if flow.upstream_body is Some(_) {
    flags = flags | 64
  }
  if flow.error is Some(_) {
    flags = flags | 128
  }
  meta.write_int_le(flags)
  write_lp_string(meta, flow.client_addr)
  write_lp_string(meta, flow.http_method)
  write_lp_string(meta, flow.target)
  write_lp_string(meta, flow.upstream)
  write_lp_string(meta, flow.reason)
  write_lp_string(meta, content_type(flow.response_headers))
  match flow.error {
    Some(e) => write_lp_string(meta, e)
    None => meta.write_int_le(0)
  }
  write_headers_bin(meta, flow.request_headers)
  write_headers_bin(meta, flow.response_headers)
  meta.to_bytes()
}

///|
fn flow_payload_length(flow : Flow, meta : Bytes) -> Int32 {
  // Four little-endian lengths, followed by metadata and the three body blobs.
  16 +
  meta.length() +
  flow.request_body.length() +
  flow.upstream_body.unwrap_or(empty_bytes).length() +
  flow.response_body.length()
}

///|
fn write_flow_payload(
  out : FixedArray[Byte],
  pos : Int32,
  flow : Flow,
  meta : Bytes,
) -> Unit {
  let pos = write_lp_bytes(out, pos, meta)
  let pos = write_lp_bytes(out, pos, flow.request_body)
  let pos = write_lp_bytes(out, pos, flow.upstream_body.unwrap_or(empty_bytes))
  ignore(write_lp_bytes(out, pos, flow.response_body))
}

///|
/// Encode one flow into its standalone binary record payload (in-memory mode).
fn encode_flow_payload(
  flow : Flow,
  total_snap : Int32,
  injected_snap : Int32,
) -> Bytes {
  let meta = encode_flow_meta(flow, total_snap, injected_snap)
  let out = FixedArray::make(flow_payload_length(flow, meta), b'\x00')
  write_flow_payload(out, 0, flow, meta)
  out.unsafe_reinterpret_as_bytes()
}

///|
fn read_lp_string(b : Bytes, pos : Int32, end : Int32) -> (String, Int32)? {
  if pos + 4 > end {
    return None
  }
  let len = read_u32_le(b, pos)
  let start = pos + 4
  if len < 0 || start + len > end {
    return None
  }
  let s = if len == 0 { "" } else { @utf8.decode_lossy(b[start:start + len]) }
  Some((s, start + len))
}

///|
fn read_lp_bytes(b : Bytes, pos : Int32, end : Int32) -> (Bytes, Int32)? {
  if pos + 4 > end {
    return None
  }
  let len = read_u32_le(b, pos)
  let start = pos + 4
  if len < 0 || start + len > end {
    return None
  }
  let data = if len == 0 {
    empty_bytes
  } else {
    b[start:start + len].to_owned()
  }
  Some((data, start + len))
}

///|
fn read_headers_bin(
  b : Bytes,
  pos : Int32,
  end : Int32,
) -> (Array[(String, String)], Int32)? {
  if pos + 4 > end {
    return None
  }
  let count = read_u32_le(b, pos)
  if count < 0 || count > 4096 {
    return None
  }
  let out : Array[(String, String)] = Array(capacity=count)
  let mut p = pos + 4
  for i = 0; i < count; i = i + 1 {
    let (k, p1) = match read_lp_string(b, p, end) {
      Some(pair) => pair
      None => return None
    }
    let (v, p2) = match read_lp_string(b, p1, end) {
      Some(pair) => pair
      None => return None
    }
    out.push((k, v))
    p = p2
  }
  Some((out, p))
}

///|
/// Decode the metadata section (`meta_bytes`) of a persisted flow record.
fn decode_meta(b : Bytes, start : Int32, end : Int32) -> DecodedMeta? {
  // Fixed header inside meta: 7*4 + 2*8 = 44 bytes (id, start_ms, end_ms,
  // status, req_size, resp_size, total_snap, inj_snap, flags).
  if start + 44 > end {
    return None
  }
  let id = read_u32_le(b, start)
  let start_ms = read_u64_le(b, start + 4)
  let end_ms = read_u64_le(b, start + 12)
  let status = read_u32_le(b, start + 20)
  let request_size = read_u32_le(b, start + 24)
  let response_size = read_u32_le(b, start + 28)
  let total_snapshot = read_u32_le(b, start + 32)
  let injected_snapshot = read_u32_le(b, start + 36)
  let flags = read_u32_le(b, start + 40)
  let mut p = start + 44
  let (client_addr, p1) = match read_lp_string(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p1
  let (http_method, p2) = match read_lp_string(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p2
  let (target, p3) = match read_lp_string(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p3
  let (upstream, p4) = match read_lp_string(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p4
  let (reason, p5) = match read_lp_string(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p5
  let (content_type, p6) = match read_lp_string(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p6
  let (err_str, p7) = match read_lp_string(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p7
  let (request_headers, p8) = match read_headers_bin(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  p = p8
  let (response_headers, _) = match read_headers_bin(b, p, end) {
    Some(pair) => pair
    None => return None
  }
  let has_error = (flags & 128) != 0
  Some({
    id,
    start_ms,
    end_ms,
    status,
    request_size,
    response_size,
    total_snapshot,
    injected_snapshot,
    request_truncated: (flags & 1) != 0,
    intercepted: (flags & 2) != 0,
    injected: (flags & 4) != 0,
    upstream_truncated: (flags & 8) != 0,
    response_truncated: (flags & 16) != 0,
    finished: (flags & 32) != 0,
    has_upstream_body: (flags & 64) != 0,
    client_addr,
    http_method,
    target,
    upstream,
    reason,
    content_type,
    error: if has_error {
      Some(err_str)
    } else {
      None
    },
    request_headers,
    response_headers,
  })
}

///|
fn DecodedMeta::to_summary(self : DecodedMeta) -> @shared.FlowSummary {
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
    duration_ms: duration_between(self.start_ms, self.end_ms),
    content_type: self.content_type,
  }
}

///|
fn DecodedMeta::to_flow_without_bodies(self : DecodedMeta) -> Flow {
  {
    id: self.id,
    start_ms: self.start_ms,
    client_addr: self.client_addr,
    http_method: self.http_method,
    target: self.target,
    request_headers: self.request_headers,
    request_size: self.request_size,
    intercepted: self.intercepted,
    upstream: self.upstream,
    request_body: empty_bytes,
    request_truncated: self.request_truncated,
    injected: self.injected,
    upstream_body: None,
    upstream_truncated: self.upstream_truncated,
    status: self.status,
    reason: self.reason,
    response_headers: self.response_headers,
    response_body: empty_bytes,
    response_size: self.response_size,
    response_truncated: self.response_truncated,
    end_ms: self.end_ms,
    error: self.error,
    finished: self.finished,
    persisted: self.finished,
  }
}

///|
/// Decode a full flow record payload (meta + 3 raw body blobs) into `FlowDetail`.
fn decode_flow_detail(payload : Bytes) -> @shared.FlowDetail? {
  let plen = payload.length()
  if plen < 4 {
    return None
  }
  let meta_len = read_u32_le(payload, 0)
  if meta_len < 0 || 4 + meta_len > plen {
    return None
  }
  let meta = match decode_meta(payload, 4, 4 + meta_len) {
    Some(m) => m
    None => return None
  }
  let mut p = 4 + meta_len
  let (req_body, p1) = match read_lp_bytes(payload, p, plen) {
    Some(pair) => pair
    None => return None
  }
  p = p1
  let (up_body, p2) = match read_lp_bytes(payload, p, plen) {
    Some(pair) => pair
    None => return None
  }
  p = p2
  let (resp_body, _) = match read_lp_bytes(payload, p, plen) {
    Some(pair) => pair
    None => return None
  }
  let request : @shared.RequestData = {
    http_method: meta.http_method,
    target: meta.target,
    headers: meta.request_headers,
    body: @utf8.decode_lossy(req_body),
    truncated: meta.request_truncated,
    size: meta.request_size,
  }
  let upstream_request : @shared.UpstreamRequest? = if meta.has_upstream_body {
    Some({
      body: @utf8.decode_lossy(up_body),
      truncated: meta.upstream_truncated,
    })
  } else {
    None
  }
  let response : @shared.ResponseData? = if meta.status == 0 &&
    meta.error is None {
    None
  } else {
    Some({
      status: meta.status,
      reason: meta.reason,
      headers: meta.response_headers,
      body: @utf8.decode_lossy(resp_body),
      truncated: meta.response_truncated,
      size: meta.response_size,
    })
  }
  Some({
    id: meta.id,
    start_ms: meta.start_ms.to_double(),
    duration_ms: duration_between(meta.start_ms, meta.end_ms),
    client_addr: meta.client_addr,
    upstream: meta.upstream,
    intercepted: meta.intercepted,
    injected: meta.injected,
    pending: !meta.finished,
    error: meta.error,
    request,
    upstream_request,
    response,
  })
}

///|
/// Scan one segment file on disk, reading ONLY each record's metadata section
/// and skipping over the raw body blobs. Stops cleanly on a partial/truncated
/// trailing record so crashes never corrupt recovery.
/// Returns `(gen, valid_end_offset, record_count, entries, last_total, last_injected)`.
async fn scan_segment_file(
  file : @fs.File,
  seg : Int32,
) -> (UInt64, Int64, Int32, Array[PersistedEntry], Int32, Int32)? {
  let fsize = file.size() catch { _ => return None }
  if fsize < seg_header_size {
    return None
  }
  let hdr = file.read_exactly_at(16, position=0L) catch { _ => return None }
  if !check_magic(hdr, 0, b"VCP1") || read_u32_le(hdr, 4) != 1 {
    return None
  }
  let gen = read_u64_le(hdr, 8)
  let entries : Array[PersistedEntry] = []
  let mut pos : Int64 = seg_header_size
  let mut count = 0
  let mut max_total = 0
  let mut max_inj = 0
  while pos + 12L <= fsize {
    let rec_hdr = file.read_exactly_at(12, position=pos) catch { _ => break }
    if !check_magic(rec_hdr, 0, b"FLW1") {
      break
    }
    let payload_len = read_u32_le(rec_hdr, 4)
    let meta_len = read_u32_le(rec_hdr, 8)
    if payload_len < 4 || meta_len < 0 || 4 + meta_len > payload_len {
      break
    }
    let next_pos = pos + rec_header_size.to_int64() + payload_len.to_int64()
    if next_pos > fsize {
      // Truncated trailing record from an abrupt crash: ignore cleanly.
      break
    }
    let meta_bytes = file.read_exactly_at(meta_len, position=pos + 12L) catch {
      _ => break
    }
    match decode_meta(meta_bytes, 0, meta_len) {
      Some(meta) => {
        if meta.total_snapshot > max_total {
          max_total = meta.total_snapshot
        }
        if meta.injected_snapshot > max_inj {
          max_inj = meta.injected_snapshot
        }
        entries.push({
          id: meta.id,
          seg,
          payload_offset: pos + rec_header_size.to_int64(),
          payload_len,
          summary: meta.to_summary(),
          mem_payload: None,
        })
        count += 1
        pos = next_pos
      }
      None => break
    }
  }
  Some((gen, pos, count, entries, max_total, max_inj))
}

///|
async fn open_or_create_segment(
  path : String,
  gen : UInt64,
  truncate~ : Bool,
) -> @fs.File {
  let file = @fs.open(
    path,
    mode=ReadWrite,
    create_mode=if truncate { CreateOrTruncate } else { OpenOrCreate },
    permission=0o600,
    sync=NoSync,
  )
  @fs.chmod(path, 0o600) catch {
    _ => ()
  }
  if truncate {
    let hdr = make_segment_header(gen)
    file.write_at(hdr[:], position=0L)
  }
  file
}

///|
/// Open (or create) the monitor directory and its rotating append-only segment
/// files (`flows.0.log` / `flows.1.log`). I/O failures degrade gracefully to an
/// in-memory store so the proxy itself is never taken down by the monitor.
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
    e => {
      println("[monitor] cannot create data dir " + dir + ": " + e.to_string())
      return FlowStore::new(capacity~)
    }
  }
  let stride = if workers > 1 { workers } else { 1 }
  let store : FlowStore = {
    dir,
    capacity,
    active: [],
    pending: [],
    next_id: 1,
    total: 0,
    injected_total: 0,
    intercept_enabled: true,
    recording: true,
    worker_id,
    workers: stride,
    id_stride: stride,
    seg_files: [None, None],
    seg_offsets: [seg_header_size, seg_header_size],
    seg_counts: [0, 0],
    active_seg: 0,
    gen: 1UL,
    persisted: [],
    flushing: [],
    clear_epoch: 0,
    flush_sem: @async.Semaphore(1),
  }
  // Recover existing segments (if any), ordered by generation.
  let scanned : Array[
    (Int32, UInt64, Int64, Int32, Array[PersistedEntry], Int32, Int32),
  ] = []
  for seg = 0; seg < 2; seg = seg + 1 {
    let path = store.seg_path(seg)
    if @fs.exists(path) {
      let opened : @fs.File? = Some(
        @fs.open(path, mode=ReadWrite, create_mode=OpenExisting, sync=NoSync),
      ) catch {
        _ => None
      }
      match opened {
        Some(f) =>
          match scan_segment_file(f, seg) {
            Some((gen, end_off, cnt, entries, tot, inj)) => {
              store.seg_files[seg] = Some(f)
              store.seg_offsets[seg] = end_off
              store.seg_counts[seg] = cnt
              scanned.push((seg, gen, end_off, cnt, entries, tot, inj))
            }
            None => f.close()
          }
        None => ()
      }
    }
  }
  scanned.sort_by((a, b) => a.1.compare(b.1))
  let mut max_id = 0
  for item in scanned {
    let (seg, gen, _end_off, _cnt, entries, tot, inj) = item
    if gen >= store.gen {
      store.gen = gen
      store.active_seg = seg
    }
    if tot > store.total {
      store.total = tot
    }
    if inj > store.injected_total {
      store.injected_total = inj
    }
    for e in entries {
      if e.id > max_id {
        max_id = e.id
      }
      store.persisted.push(e)
    }
  }
  store.persisted.sort_by((a, b) => b.id - a.id)
  if store.capacity > 0 && store.persisted.length() > store.capacity {
    store.persisted.truncate(store.capacity)
  }
  store.next_id = max_id + 1
  if stride > 1 {
    let offset = if worker_id >= 0 { worker_id % stride } else { 0 }
    let base = store.next_id
    let rem = (base - 1) % stride
    let adjust = (offset - rem + stride) % stride
    store.next_id = base + adjust
  }
  // Ensure active segment file exists and has a valid 16-byte header.
  if store.seg_files[store.active_seg] is None {
    let path = store.seg_path(store.active_seg)
    let f : @fs.File? = Some(
      open_or_create_segment(path, store.gen, truncate=true),
    ) catch {
      e => {
        println("[monitor] cannot open " + path + ": " + e.to_string())
        None
      }
    }
    match f {
      Some(file) => {
        store.seg_files[store.active_seg] = Some(file)
        store.seg_offsets[store.active_seg] = seg_header_size
        store.seg_counts[store.active_seg] = 0
      }
      None => {
        store.close_files()
        println("[monitor] cannot use " + dir + ", falling back to memory")
        return FlowStore::new(capacity~)
      }
    }
  }
  store
}

///|
fn FlowStore::close_files(self : FlowStore) -> Unit {
  for i = 0; i < 2; i = i + 1 {
    match self.seg_files[i] {
      Some(f) => {
        f.close()
        self.seg_files[i] = None
      }
      None => ()
    }
  }
}

///|
/// Flush remaining flows and close underlying segment files.
pub async fn FlowStore::close(self : FlowStore) -> Unit {
  self.flush_pending()
  self.close_files()
}

///|
/// Register a new flow (request fully read, response pending). Pure in-memory
/// on the proxy hot path — zero disk I/O.
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
  self.active.push(flow)
  flow
}

///|
/// Mark a flow complete (idempotent) and queue it for batched async append.
pub fn FlowStore::finish(self : FlowStore, flow : Flow) -> Unit {
  if !self.recording || flow.finished {
    return
  }
  flow.finished = true
  flow.end_ms = @env.now()
  if !self.take_active(flow.id) {
    // Cleared while the request was still in flight.
    return
  }
  if flow.injected {
    self.injected_total += 1
  }
  self.pending.push(flow)
  // Guard memory under extreme bursts: never retain more than 2x capacity in
  // the un-flushed queue (older entries would be immediately evicted on flush).
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
fn FlowStore::has_persisted_in_seg(self : FlowStore, seg : Int32) -> Bool {
  for e in self.persisted {
    if e.seg == seg {
      return true
    }
  }
  false
}

///|
/// Rotate to the inactive segment when the active segment already holds at
/// least `capacity` records and the inactive segment has no live entries.
/// Truncating the inactive segment reclaims disk space with zero bytes copied.
async fn FlowStore::maybe_rotate(self : FlowStore) -> Unit {
  if self.dir.is_empty() || self.capacity <= 0 {
    return
  }
  if self.seg_counts[self.active_seg] < self.capacity {
    return
  }
  let other = 1 - self.active_seg
  if self.has_persisted_in_seg(other) {
    return
  }
  match self.seg_files[other] {
    Some(f) => {
      f.close()
      self.seg_files[other] = None
    }
    None => ()
  }
  let next_gen = self.gen + 1UL
  let path = self.seg_path(other)
  let new_file : @fs.File? = Some(
    open_or_create_segment(path, next_gen, truncate=true),
  ) catch {
    e => {
      println("[monitor] cannot rotate segment " + path + ": " + e.to_string())
      None
    }
  }
  match new_file {
    Some(f) => {
      self.gen = next_gen
      self.seg_files[other] = Some(f)
      self.seg_offsets[other] = seg_header_size
      self.seg_counts[other] = 0
      self.active_seg = other
    }
    None => ()
  }
}

///|
/// Persist all surviving finished flows in ONE sequential async file append
/// (executed off the event loop in `moonbitlang/async`'s C worker thread pool)
/// and release their in-memory bodies.
pub async fn FlowStore::flush_pending(self : FlowStore) -> Unit {
  if !self.recording || self.pending.length() == 0 {
    return
  }
  self.flush_sem.acquire()
  defer self.flush_sem.release()
  if !self.recording || self.pending.length() == 0 {
    return
  }
  let epoch = self.clear_epoch
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
    self.persisted.length() + batch.length()
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
  let to_write = batch.length() - skip
  if to_write == 0 {
    if self.capacity > 0 && self.persisted.length() > keep {
      self.persisted.truncate(keep)
    }
    return
  }
  let total_snap = self.total
  let inj_snap = self.injected_total
  if self.dir.is_empty() {
    // In-memory store (tests / fallback): encode into memory using the exact
    // same binary format, then clear live Flow bodies.
    for i = skip; i < batch.length(); i = i + 1 {
      let flow = batch[i]
      let payload = encode_flow_payload(flow, total_snap, inj_snap)
      self.persisted.push({
        id: flow.id,
        seg: 0,
        payload_offset: 0L,
        payload_len: payload.length(),
        summary: flow.summary(),
        mem_payload: Some(payload),
      })
      flow.persisted = true
      flow.request_body = empty_bytes
      flow.upstream_body = None
      flow.response_body = empty_bytes
    }
    self.persisted.sort_by((a, b) => b.id - a.id)
    if self.capacity > 0 && self.persisted.length() > keep {
      self.persisted.truncate(keep)
    }
    return
  }
  // Keep flows readable from memory while the async write runs off-thread.
  self.flushing = batch
  defer {
    self.flushing = []
  }
  self.maybe_rotate()
  if self.clear_epoch != epoch {
    return
  }
  let seg = self.active_seg
  let base_offset = self.seg_offsets[seg]
  // Compute the exact batch size from metadata encoded once per flow.
  let metadata : Array[Bytes] = Array(capacity=to_write)
  let mut batch_size = 0
  for i = skip; i < batch.length(); i = i + 1 {
    let flow = batch[i]
    let meta = encode_flow_meta(flow, total_snap, inj_snap)
    metadata.push(meta)
    batch_size += rec_header_size + flow_payload_length(flow, meta)
  }
  let write_buf = FixedArray::make(batch_size, b'\x00')
  let new_entries : Array[PersistedEntry] = Array(capacity=to_write)
  let mut rel_off = 0
  for i = skip; i < batch.length(); i = i + 1 {
    let flow = batch[i]
    let meta = metadata[i - skip]
    let plen = flow_payload_length(flow, meta)
    let payload_pos = rel_off + rec_header_size
    write_buf.blit_from_bytes(rel_off, b"FLW1", 0, 4)
    write_u32_le(write_buf, rel_off + 4, plen)
    write_flow_payload(write_buf, payload_pos, flow, meta)
    new_entries.push({
      id: flow.id,
      seg,
      payload_offset: base_offset + payload_pos.to_int64(),
      payload_len: plen,
      summary: flow.summary(),
      mem_payload: None,
    })
    rel_off = payload_pos + plen
  }
  // The batch is complete and its backing array is no longer mutated.
  let bytes_to_write = write_buf.unsafe_reinterpret_as_bytes()
  let wrote = match self.seg_files[seg] {
    Some(file) =>
      try {
        file.write_at(bytes_to_write[:], position=base_offset)
        true
      } catch {
        e => {
          println("[monitor] append write failed: " + e.to_string())
          false
        }
      }
    None => false
  }
  if self.clear_epoch != epoch {
    return
  }
  if wrote {
    self.seg_offsets[seg] = base_offset + bytes_to_write.length().to_int64()
    self.seg_counts[seg] += to_write
    for entry in new_entries {
      self.persisted.push(entry)
    }
    self.persisted.sort_by((a, b) => b.id - a.id)
    let keep_now = if self.capacity > 0 {
      let k = self.capacity - self.active.length()
      if k > 0 {
        k
      } else {
        0
      }
    } else {
      self.persisted.length()
    }
    if self.capacity > 0 && self.persisted.length() > keep_now {
      self.persisted.truncate(keep_now)
    }
  }
  for i = skip; i < batch.length(); i = i + 1 {
    let flow = batch[i]
    flow.persisted = wrote
    flow.request_body = empty_bytes
    flow.upstream_body = None
    flow.response_body = empty_bytes
  }
}

///|
/// Background flusher: batch-append finished flows off the event loop every
/// ~100ms so the proxy hot path never blocks on disk I/O.
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
/// Clear the in-memory index, truncate/reset segment files, and zero counters.
pub async fn FlowStore::clear(self : FlowStore) -> Unit {
  self.clear_epoch += 1
  self.active = []
  self.pending = []
  self.flushing = []
  self.persisted = []
  self.total = 0
  self.injected_total = 0
  self.next_id = 1
  if !self.recording || self.dir.is_empty() {
    return
  }
  self.flush_sem.acquire()
  defer self.flush_sem.release()
  self.close_files()
  if self.workers > 1 {
    for w = 0; w < self.workers; w = w + 1 {
      for seg = 0; seg < 2; seg = seg + 1 {
        @fs.remove(
          segment_path_for(self.dir, w, self.workers, seg),
          allow_missing=true,
        ) catch {
          _ => ()
        }
      }
    }
  } else {
    for seg = 0; seg < 2; seg = seg + 1 {
      @fs.remove(self.seg_path(seg), allow_missing=true) catch {
        _ => ()
      }
    }
  }
  self.active_seg = 0
  self.gen = 1UL
  self.seg_offsets = [seg_header_size, seg_header_size]
  self.seg_counts = [0, 0]
  let path = self.seg_path(0)
  let f : @fs.File? = Some(
    open_or_create_segment(path, self.gen, truncate=true),
  ) catch {
    e => {
      println("[monitor] cannot reset segment " + path + ": " + e.to_string())
      None
    }
  }
  self.seg_files[0] = f
}

///|
async fn FlowStore::read_entry_payload(
  self : FlowStore,
  entry : PersistedEntry,
) -> Bytes? {
  match entry.mem_payload {
    Some(b) => Some(b)
    None =>
      match self.seg_files[entry.seg] {
        Some(file) =>
          Some(
            file.read_exactly_at(
              entry.payload_len,
              position=entry.payload_offset,
            ),
          ) catch {
            _ => None
          }
        None => None
      }
  }
}

///|
/// Look up a flow by id (metadata only for persisted flows).
pub async fn FlowStore::find(self : FlowStore, id : Int32) -> Flow? {
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
  for flow in self.flushing {
    if flow.id == id {
      return Some(flow)
    }
  }
  for entry in self.persisted {
    if entry.id == id {
      match self.read_entry_payload(entry) {
        Some(payload) =>
          if payload.length() >= 4 {
            let meta_len = read_u32_le(payload, 0)
            if meta_len >= 0 && 4 + meta_len <= payload.length() {
              match decode_meta(payload, 4, 4 + meta_len) {
                Some(meta) => return Some(meta.to_flow_without_bodies())
                None => ()
              }
            }
          }
        None => ()
      }
    }
  }
  None
}

///|
/// Scan sibling workers' segment files in multi-worker mode to locate one flow
/// detail by id.
async fn FlowStore::detail_from_peer_workers(
  self : FlowStore,
  id : Int32,
) -> @shared.FlowDetail? {
  if self.workers <= 1 || self.dir.is_empty() {
    return None
  }
  for w = 0; w < self.workers; w = w + 1 {
    if w == self.worker_id {
      continue
    }
    for seg = 0; seg < 2; seg = seg + 1 {
      let path = segment_path_for(self.dir, w, self.workers, seg)
      if !@fs.exists(path) {
        continue
      }
      let opened : @fs.File? = Some(
        @fs.open(path, mode=ReadOnly, create_mode=OpenExisting),
      ) catch {
        _ => None
      }
      match opened {
        Some(file) => {
          defer file.close()
          match scan_segment_file(file, seg) {
            Some((_, _, _, entries, _, _)) =>
              for e in entries {
                if e.id == id {
                  let payload : Bytes? = Some(
                    file.read_exactly_at(
                      e.payload_len,
                      position=e.payload_offset,
                    ),
                  ) catch {
                    _ => None
                  }
                  match payload {
                    Some(p) =>
                      match decode_flow_detail(p) {
                        Some(d) => return Some(d)
                        None => ()
                      }
                    None => ()
                  }
                }
              }
            None => ()
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
/// Full detail of one flow: served from memory while in flight / pending, or
/// via a single async `pread` (`File::read_exactly_at`) once persisted.
pub async fn FlowStore::detail(
  self : FlowStore,
  id : Int32,
) -> @shared.FlowDetail? {
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
  for flow in self.flushing {
    if flow.id == id {
      return Some(flow.detail())
    }
  }
  for entry in self.persisted {
    if entry.id == id {
      match self.read_entry_payload(entry) {
        Some(payload) => return decode_flow_detail(payload)
        None => return None
      }
    }
  }
  self.detail_from_peer_workers(id)
}

///|
/// Flow list API payload (newest first, shared contract type). In single-worker
/// mode this is served 100% from memory (zero disk I/O); in multi-worker mode
/// it merges metadata headers from sibling workers' logs.
pub async fn FlowStore::list_response(
  self : FlowStore,
) -> @shared.FlowsResponse {
  let flows : Array[@shared.FlowSummary] = Array(
    capacity=self.persisted.length() +
      self.flushing.length() +
      self.pending.length() +
      self.active.length(),
  )
  for entry in self.persisted {
    flows.push(entry.summary)
  }
  for flow in self.flushing {
    flows.push(flow.summary())
  }
  for flow in self.pending {
    flows.push(flow.summary())
  }
  for flow in self.active {
    flows.push(flow.summary())
  }
  let mut total = self.total
  let mut injected_total = self.injected_total
  if self.workers > 1 && self.recording && !self.dir.is_empty() {
    for w = 0; w < self.workers; w = w + 1 {
      if w == self.worker_id {
        continue
      }
      let mut w_tot = 0
      let mut w_inj = 0
      for seg = 0; seg < 2; seg = seg + 1 {
        let path = segment_path_for(self.dir, w, self.workers, seg)
        if !@fs.exists(path) {
          continue
        }
        let opened : @fs.File? = Some(
          @fs.open(path, mode=ReadOnly, create_mode=OpenExisting),
        ) catch {
          _ => None
        }
        match opened {
          Some(file) => {
            defer file.close()
            match scan_segment_file(file, seg) {
              Some((_, _, _, entries, tot, inj)) => {
                if tot > w_tot {
                  w_tot = tot
                }
                if inj > w_inj {
                  w_inj = inj
                }
                for e in entries {
                  flows.push(e.summary)
                }
              }
              None => ()
            }
          }
          None => ()
        }
      }
      total += w_tot
      injected_total += w_inj
    }
  }
  flows.sort_by((a, b) => b.id - a.id)
  if self.capacity > 0 && flows.length() > self.capacity {
    flows.truncate(self.capacity)
  }
  {
    total,
    injected_total,
    stored: flows.length(),
    capacity: self.capacity,
    intercept_enabled: self.intercept_enabled,
    flows,
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
          out.write_bytesview(v.clamped_view(start=data_start))
          break
        }
        out.write_bytesview(
          v.clamped_view(start=data_start, end=data_start + size),
        )
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
