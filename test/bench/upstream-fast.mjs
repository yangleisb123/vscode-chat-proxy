// Minimal keep-alive upstream: drains the body without parsing it, then
// returns JSON or the requested number of HTTP chunks carrying SSE events.
// Usage: node upstream-fast.mjs <port>
import http from "node:http";
const port = Number(process.argv[2] || 18080);
const body = Buffer.from('{"ok":true,"model":"bench"}');
const event = Buffer.from('data: {"model":"bench","delta":"token"}\n\n');
const done = Buffer.from('data: [DONE]\n\n');
const srv = http.createServer((req, res) => {
  const chunks = Number(req.headers["x-bench-sse-chunks"] ?? 0);
  if (!Number.isInteger(chunks) || chunks < 0 || chunks > 1000) {
    res.writeHead(400).end();
    return;
  }
  req.once("end", () => {
    if (chunks > 0) {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
      });
      // Write individual HTTP chunks with no artificial upstream delay.
      for (let i = 1; i < chunks; i++) res.write(event);
      res.end(done);
    } else {
      res.writeHead(200, {
        "Content-Type": "application/json",
        "Content-Length": body.length,
      });
      res.end(body);
    }
  });
  req.resume();
});
srv.keepAliveTimeout = 65000;
srv.listen(port, "127.0.0.1", () => console.log("upstream-fast on", port));
