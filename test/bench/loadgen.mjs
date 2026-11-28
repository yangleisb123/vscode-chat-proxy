// Fixed-concurrency HTTP benchmark. Latencies are for completed 2xx responses.
// Usage: node loadgen.mjs <direct|proxy> <proxyPort> <targetPort> <conc> <secs> [keepalive=1] [bodyBytes] [sseChunks=0]
// The default body is a small JSON POST. Set bodyBytes to 65536 for a 64 KiB body.
// In proxy mode the request uses the absolute-form target.
import http from "node:http";

const [mode, proxyPort, targetPort, conc, secs, ka, bodyBytes, sseChunks = "0"] =
  process.argv.slice(2);
const concurrency = Number(conc);
const duration = Number(secs);
const chunks = Number(sseChunks);
const upstreamPort = Number(targetPort);
const listenPort = mode === "proxy" ? Number(proxyPort) : upstreamPort;

function validPort(port) {
  return Number.isInteger(port) && port >= 1 && port <= 65535;
}

if ((mode !== "direct" && mode !== "proxy") ||
    !validPort(upstreamPort) || !validPort(listenPort) ||
    !Number.isSafeInteger(concurrency) || concurrency < 1 ||
    !Number.isFinite(duration) || duration <= 0 || duration > 2147483 ||
    !Number.isInteger(chunks) || chunks < 0 || chunks > 1000) {
  throw new Error("Invalid benchmark mode, port, concurrency, duration or SSE chunk count");
}

const requestBody = { model: "bench", messages: [{ role: "user", content: "hi" }] };
if (chunks > 0) requestBody.stream = true;
if (bodyBytes !== undefined) {
  const bytes = Number(bodyBytes);
  const minimum = Buffer.byteLength(JSON.stringify(requestBody));
  if (!Number.isInteger(bytes) || bytes < minimum || bytes > 64 * 1024 * 1024) {
    throw new Error("bodyBytes must fit the minimum JSON payload and the 64 MiB proxy limit");
  }
  requestBody.messages[0].content += "a".repeat(bytes - minimum);
}
const payload = Buffer.from(JSON.stringify(requestBody));
const agent = new http.Agent({
  keepAlive: ka !== "0",
  maxSockets: concurrency,
  maxFreeSockets: concurrency,
});

const authority = "127.0.0.1:" + upstreamPort;
const route = "/v1/chat/completions";
const options = {
  host: "127.0.0.1",
  port: listenPort,
  method: "POST",
  path: mode === "proxy" ? "http://" + authority + route : route,
  headers: {
    "Content-Type": "application/json",
    "Content-Length": payload.length,
    Host: authority,
    ...(chunks > 0 ? { "X-Bench-Sse-Chunks": chunks } : {}),
  },
  agent,
};

const latency = [];
const firstByte = [];
const failures = {
  http: 0,
  transport: 0,
  aborted: 0,
  timeout: 0,
  unexpectedResponse: 0,
};
const httpStatuses = {};
const start = performance.now();
const stopAt = start + duration * 1000;
let workers = concurrency;

function one() {
  const started = performance.now();
  if (started >= stopAt) {
    workers--;
    if (workers === 0) report();
    return;
  }

  let settled = false;
  let firstBodyByte;
  function finish(failure) {
    if (settled) return;
    settled = true;
    clearTimeout(deadline);
    if (failure) {
      failures[failure]++;
      // Back off on errors so a closed listener does not burn through local ports.
      setTimeout(one, 10);
    } else {
      latency.push(performance.now() - started);
      if (firstBodyByte !== undefined) firstByte.push(firstBodyByte);
      one();
    }
  }

  const req = http.request(options, (res) => {
    res.once("data", () => { firstBodyByte = performance.now() - started; });
    res.once("end", () => {
      if (res.statusCode < 200 || res.statusCode >= 300) {
        httpStatuses[res.statusCode] = (httpStatuses[res.statusCode] ?? 0) + 1;
        finish("http");
      } else if (chunks > 0 &&
          (!res.headers["content-type"]?.startsWith("text/event-stream") ||
           firstBodyByte === undefined)) {
        finish("unexpectedResponse");
      } else {
        finish();
      }
    });
    res.once("aborted", () => finish("aborted"));
    res.once("error", () => finish("aborted"));
    res.resume();
  });
  req.once("error", () => finish("transport"));
  const deadline = setTimeout(() => {
    finish("timeout");
    req.destroy();
  }, 10_000);
  req.end(payload);
}

function percentile(samples, p) {
  if (samples.length === 0) return null;
  return +samples[Math.ceil(p * samples.length) - 1].toFixed(2);
}

function report() {
  const elapsed = (performance.now() - start) / 1000;
  agent.destroy();
  latency.sort((a, b) => a - b);
  firstByte.sort((a, b) => a - b);
  console.log(JSON.stringify({
    mode,
    conc: concurrency,
    secs: duration,
    elapsed: +elapsed.toFixed(3),
    bodyBytes: payload.length,
    sseChunks: chunks,
    requests: latency.length,
    errors: Object.values(failures).reduce((sum, n) => sum + n, 0),
    failures,
    httpStatuses,
    rps: Math.round(latency.length / elapsed),
    p50: percentile(latency, 0.50),
    p95: percentile(latency, 0.95),
    p99: percentile(latency, 0.99),
    firstByteP95: percentile(firstByte, 0.95),
    firstByteP99: percentile(firstByte, 0.99),
  }));
}

for (let i = 0; i < concurrency; i++) one();
