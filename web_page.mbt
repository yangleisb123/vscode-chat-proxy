///|
/// The monitor web UI (single-file HTML + vanilla JS, mitmweb style).
/// Served at `GET /` by the monitor web server.
let web_page : String =
  #|<!doctype html>
  #|<html lang="zh">
  #|<head>
  #|<meta charset="utf-8">
  #|<meta name="viewport" content="width=device-width, initial-scale=1">
  #|<title>vscode-chat-proxy · 请求监控</title>
  #|<style>
  #|:root { color-scheme: dark; }
  #|* { box-sizing: border-box; }
  #|body { margin:0; font:13px/1.5 "Segoe UI","Microsoft YaHei",sans-serif; background:#1b1d23; color:#d6d9e0; height:100vh; display:flex; flex-direction:column; }
  #|header { display:flex; align-items:center; gap:10px; padding:8px 12px; background:#23262e; border-bottom:1px solid #333742; flex-wrap:wrap; }
  #|h1 { font-size:15px; margin:0; }
  #|h1 span { color:#8a90a0; font-weight:normal; font-size:12px; }
  #|#stats { color:#8a90a0; font-size:12px; }
  #|input, button { background:#2b2f38; color:#d6d9e0; border:1px solid #3a3f4b; border-radius:4px; padding:4px 8px; font-size:12px; }
  #|button { cursor:pointer; }
  #|button:hover { background:#343945; }
  #|button.on { background:#3d5a80; border-color:#5a7fa8; }
  #|#filter { min-width:180px; }
  #|main { flex:1; display:flex; min-height:0; }
  #|#list { flex:1.15; overflow:auto; border-right:1px solid #333742; min-width:0; }
  #|#detail { flex:1; overflow:auto; padding:10px 12px; min-width:0; }
  #|table.flows { width:100%; border-collapse:collapse; font-size:12px; }
  #|table.flows th { position:sticky; top:0; background:#23262e; text-align:left; padding:5px 8px; border-bottom:1px solid #333742; color:#8a90a0; font-weight:600; z-index:1; }
  #|table.flows td { padding:4px 8px; border-bottom:1px solid #262932; white-space:nowrap; }
  #|table.flows tr { cursor:pointer; }
  #|table.flows tr:hover { background:#262a33; }
  #|table.flows tr.sel { background:#2e3a4d; }
  #|td.path { max-width:340px; overflow:hidden; text-overflow:ellipsis; }
  #|td.st.good { color:#7ec699; }
  #|td.st.bad { color:#e06c75; }
  #|td.st.pending { color:#d19a66; }
  #|td.inj { color:#7ec699; }
  #|tr.err td { color:#e06c75; }
  #|.empty { color:#6b7280; padding:30px; text-align:center; }
  #|.dbar { display:flex; flex-direction:column; gap:2px; margin-bottom:8px; }
  #|.dbar span:first-child { font-weight:600; font-size:13px; word-break:break-all; }
  #|.dmeta { color:#8a90a0; font-size:11px; }
  #|.errbox { background:#3a2426; color:#e06c75; padding:6px 8px; border-radius:4px; margin-bottom:8px; }
  #|.tabs { display:flex; gap:6px; margin-bottom:8px; }
  #|.tabs button.on { background:#3d5a80; border-color:#5a7fa8; }
  #|.line { font-family:Consolas,monospace; background:#23262e; padding:5px 8px; border-radius:4px; margin-bottom:6px; word-break:break-all; }
  #|table.hdrs { width:100%; border-collapse:collapse; font-size:12px; margin-bottom:8px; }
  #|table.hdrs td { padding:2px 6px; border-bottom:1px solid #262932; vertical-align:top; }
  #|table.hdrs td:first-child { color:#8a90a0; width:180px; word-break:break-all; }
  #|table.hdrs td:last-child { word-break:break-all; }
  #|.bnote { color:#8a90a0; font-size:11px; margin:4px 0; }
  #|pre { background:#15171c; border:1px solid #2a2e37; border-radius:4px; padding:8px; overflow:auto; max-height:46vh; font:12px/1.5 Consolas,"Courier New",monospace; white-space:pre-wrap; word-break:break-all; margin:0; }
  #|@media (max-width:900px) { main { flex-direction:column; } #list { border-right:none; border-bottom:1px solid #333742; max-height:45%; } }
  #|</style>
  #|</head>
  #|<body>
  #|<header>
  #|<h1>vscode-chat-proxy <span>请求监控</span></h1>
  #|<div id="stats">加载中…</div>
  #|<input id="filter" placeholder="过滤 path / method…">
  #|<button id="pause">暂停</button>
  #|<button id="clear">清空</button>
  #|</header>
  #|<main>
  #|<div id="list">
  #|<table class="flows">
  #|<thead><tr><th>#</th><th>时间</th><th>方法</th><th>路径</th><th>状态</th><th>标记</th><th>大小 入/出</th><th>耗时</th></tr></thead>
  #|<tbody id="rows"></tbody>
  #|</table>
  #|</div>
  #|<div id="detail"><div class="empty">点击左侧请求查看入参 / 出参</div></div>
  #|</main>
  #|<script>
  #|const $ = (id) => document.getElementById(id);
  #|let flows = [], selectedId = null, paused = false, detailTab = 'request', detail = null;
  #|function fmtSize(n) { if (n < 1024) return n + ' B'; if (n < 1048576) return (n/1024).toFixed(1) + ' K'; return (n/1048576).toFixed(2) + ' M'; }
  #|function fmtTime(ms) { return new Date(ms).toLocaleTimeString('zh-CN', {hour12:false}); }
  #|function headerVal(headers, name) { for (const [k,v] of headers||[]) if (k.toLowerCase()===name) return v; return ''; }
  #|async function refresh() {
  #|  if (paused) return;
  #|  try {
  #|    const r = await fetch('/api/flows');
  #|    const data = await r.json();
  #|    flows = data.flows || [];
  #|    $('stats').textContent = '共 ' + data.total + ' 条 · 已注入 ' + data.injected_total + ' · 缓存 ' + data.stored + '/' + data.capacity;
  #|    renderRows();
  #|    if (selectedId != null) {
  #|      const f = flows.find(x => x.id === selectedId);
  #|      if (!f) { selectedId = null; detail = null; renderDetail(); }
  #|      else if (f.pending || !detail) loadDetail(selectedId);
  #|    }
  #|  } catch (e) { $('stats').textContent = '无法连接代理监控端口…'; }
  #|}
  #|function renderRows() {
  #|  const q = $('filter').value.trim().toLowerCase();
  #|  const tb = $('rows'); tb.innerHTML = '';
  #|  for (const f of flows) {
  #|    if (q && !(f.path.toLowerCase().includes(q) || f.method.toLowerCase().includes(q))) continue;
  #|    const tr = document.createElement('tr');
  #|    if (f.id === selectedId) tr.className = 'sel';
  #|    if (f.error) tr.classList.add('err');
  #|    const cells = [
  #|      '#' + f.id, fmtTime(f.start_ms), f.method, f.path,
  #|      f.pending ? '…' : String(f.status),
  #|      (f.injected ? '已注入 ' : '') + (f.intercepted ? '拦截' : ''),
  #|      fmtSize(f.req_size) + ' / ' + fmtSize(f.resp_size),
  #|      f.pending ? '' : f.duration_ms + ' ms'
  #|    ];
  #|    cells.forEach((c, i) => {
  #|      const td = document.createElement('td'); td.textContent = c;
  #|      if (i === 3) td.className = 'path';
  #|      if (i === 4) td.className = 'st ' + (f.pending ? 'pending' : ((f.status >= 400 || f.error) ? 'bad' : (f.status >= 200 && f.status < 300 ? 'good' : '')));
  #|      if (i === 5 && f.injected) td.className = 'inj';
  #|      tr.appendChild(td);
  #|    });
  #|    tr.onclick = () => { selectedId = f.id; detailTab = 'request'; loadDetail(f.id); renderRows(); };
  #|    tb.appendChild(tr);
  #|  }
  #|}
  #|async function loadDetail(id) {
  #|  try {
  #|    const r = await fetch('/api/flows/' + id);
  #|    if (!r.ok) return;
  #|    detail = await r.json();
  #|    renderDetail();
  #|  } catch (e) {}
  #|}
  #|function pretty(body, contentType) {
  #|  if (body == null) return '';
  #|  const t = (contentType || '').toLowerCase();
  #|  if (t.includes('json') || /^\s*[{[]/.test(body)) {
  #|    try { return JSON.stringify(JSON.parse(body), null, 2); } catch (e) {}
  #|  }
  #|  return body;
  #|}
  #|function headersTable(headers) {
  #|  const tbl = document.createElement('table'); tbl.className = 'hdrs';
  #|  for (const [k, v] of headers || []) {
  #|    const tr = document.createElement('tr');
  #|    const td1 = document.createElement('td'); td1.textContent = k;
  #|    const td2 = document.createElement('td'); td2.textContent = v;
  #|    tr.appendChild(td1); tr.appendChild(td2); tbl.appendChild(tr);
  #|  }
  #|  return tbl;
  #|}
  #|function bodyBlock(body, truncated, ct, size) {
  #|  const wrap = document.createElement('div');
  #|  const note = document.createElement('div'); note.className = 'bnote';
  #|  note.textContent = 'Body（' + fmtSize(size || 0) + '）' + (truncated ? ' · 已截断，仅保存前 256 KiB' : '');
  #|  wrap.appendChild(note);
  #|  const pre = document.createElement('pre'); pre.textContent = pretty(body, ct) || '（空）';
  #|  wrap.appendChild(pre);
  #|  return wrap;
  #|}
  #|function renderDetail() {
  #|  const box = $('detail'); box.innerHTML = '';
  #|  if (!detail) { box.innerHTML = '<div class="empty">点击左侧请求查看入参 / 出参</div>'; return; }
  #|  const d = detail;
  #|  const bar = document.createElement('div'); bar.className = 'dbar';
  #|  const title = document.createElement('span');
  #|  title.textContent = '#' + d.id + ' ' + d.request.method + ' ' + d.request.target;
  #|  bar.appendChild(title);
  #|  const meta = document.createElement('span'); meta.className = 'dmeta';
  #|  meta.textContent = (d.pending ? '进行中' : d.duration_ms + ' ms') + ' · 客户端 ' + d.client_addr + ' · 上游 ' + d.upstream + (d.injected ? ' · 已注入 system 前缀' : '');
  #|  bar.appendChild(meta);
  #|  box.appendChild(bar);
  #|  if (d.error) { const e = document.createElement('div'); e.className = 'errbox'; e.textContent = '错误：' + d.error; box.appendChild(e); }
  #|  const tabs = document.createElement('div'); tabs.className = 'tabs';
  #|  const mk = (key, label) => { const b = document.createElement('button'); b.textContent = label; b.className = detailTab === key ? 'on' : ''; b.onclick = () => { detailTab = key; renderDetail(); }; tabs.appendChild(b); };
  #|  mk('request', '请求（入参）');
  #|  mk('response', '响应（出参）');
  #|  if (d.injected && d.upstream_request) mk('diff', '注入后转发体');
  #|  box.appendChild(tabs);
  #|  const pane = document.createElement('div'); pane.className = 'pane';
  #|  if (detailTab === 'request' || detailTab === 'diff') {
  #|    const req = d.request;
  #|    const info = document.createElement('div'); info.className = 'line';
  #|    info.textContent = req.method + ' ' + req.target + ' HTTP/1.1';
  #|    pane.appendChild(info);
  #|    pane.appendChild(headersTable(req.headers));
  #|    const isDiff = detailTab === 'diff';
  #|    const body = isDiff ? d.upstream_request.body : req.body;
  #|    const trunc = isDiff ? d.upstream_request.truncated : req.truncated;
  #|    const ct = isDiff ? 'application/json' : headerVal(req.headers, 'content-type');
  #|    pane.appendChild(bodyBlock(body, trunc, ct, req.size));
  #|  } else {
  #|    const resp = d.response;
  #|    if (!resp) { const e = document.createElement('div'); e.className = 'empty'; e.textContent = d.pending ? '等待上游响应…' : '无响应'; pane.appendChild(e); }
  #|    else {
  #|      const info = document.createElement('div'); info.className = 'line';
  #|      info.textContent = 'HTTP/1.1 ' + resp.status + ' ' + resp.reason;
  #|      pane.appendChild(info);
  #|      pane.appendChild(headersTable(resp.headers));
  #|      pane.appendChild(bodyBlock(resp.body, resp.truncated, headerVal(resp.headers, 'content-type'), resp.size));
  #|    }
  #|  }
  #|  box.appendChild(pane);
  #|}
  #|$('pause').onclick = () => { paused = !paused; $('pause').textContent = paused ? '继续' : '暂停'; $('pause').classList.toggle('on', paused); if (!paused) refresh(); };
  #|$('clear').onclick = async () => { await fetch('/api/flows', {method:'DELETE'}); selectedId = null; detail = null; renderDetail(); refresh(); };
  #|$('filter').oninput = renderRows;
  #|refresh();
  #|setInterval(refresh, 1500);
  #|</script>
  #|</body>
  #|</html>
