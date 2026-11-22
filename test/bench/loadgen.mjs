// Load generator: fixed concurrency for N seconds, keep-alive, small POST.
// Usage: node loadgen.mjs <direct|proxy> <proxyPort> <targetPort> <conc> <secs> [keepalive=1]
// direct: POST http://127.0.0.1:<targetPort>/v1/chat/completions
// proxy : POST http://127.0.0.1:<proxyPort> with absolute-form target
//         http://127.0.0.1:<targetPort>/v1/chat/completions
import http from "node:http";

const [mode, proxyPort, targetPort, conc, secs, ka] = process.argv.slice(2);
const C = Number(conc), D = Number(secs);
const keepAlive = ka !== "0";
const target = `http://127.0.0.1:${targetPort}/v1/chat/completions`;
const payload = Buffer.from(
  JSON.stringify({ model: "bench", messages: [{ role: "user", content: "hi" }] }),
);
const agent = new http.Agent({ keepAlive, maxSockets: C, maxFreeSockets: C });

const lat = [];
let done = 0, errors = 0, inflight = 0;
const stopAt = Date.now() + D * 1000;
let stopping = false;

function opts() {
  if (mode === "proxy") {
    return {
      host: "127.0.0.1", port: Number(proxyPort), method: "POST", path: target,
      headers: {
        "Content-Type": "application/json",
        "Content-Length": payload.length,
        Host: `127.0.0.1:${targetPort}`,
      },
      agent,
    };
  }
  return {
    host: "127.0.0.1", port: Number(targetPort), method: "POST",
    path: "/v1/chat/completions",
    headers: { "Content-Type": "application/json", "Content-Length": payload.length },
    agent,
  };
}

function one() {
  if (stopping) return;
  inflight++;
  const t0 = process.hrtime.bigint();
  const req = http.request(opts(), (res) => {
    res.resume();
    res.on("end", () => {
      const ms = Number(process.hrtime.bigint() - t0) / 1e6;
      lat.push(ms); done++; inflight--;
      if (Date.now() < stopAt) one(); else maybeFinish();
    });
  });
  req.on("error", () => { errors++; inflight--; if (Date.now() < stopAt) one(); else maybeFinish(); });
  req.end(payload);
}
function maybeFinish() {
  if (stopping && inflight === 0) report();
}
function report() {
  lat.sort((a, b) => a - b);
  const q = (p) => lat.length ? lat[Math.min(lat.length - 1, Math.floor(p * lat.length))] : 0;
  const elapsed = D;
  console.log(JSON.stringify({
    mode, conc: C, secs: D,
    requests: done, errors,
    rps: Math.round(done / elapsed),
    p50: +q(0.5).toFixed(2), p95: +q(0.95).toFixed(2), p99: +q(0.99).toFixed(2),
  }));
  process.exit(0);
}
setTimeout(() => { stopping = true; maybeFinish(); }, D * 1000);
for (let i = 0; i < C; i++) one();