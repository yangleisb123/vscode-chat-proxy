// Minimal keep-alive upstream: responds immediately, does not parse body.
// Usage: node upstream-fast.mjs <port>
import http from "node:http";
const port = Number(process.argv[2] || 18080);
const body = Buffer.from('{"ok":true,"model":"bench"}');
const srv = http.createServer((req, res) => {
  req.resume(); // drain request body without parsing
  res.writeHead(200, {
    "Content-Type": "application/json",
    "Content-Length": body.length,
  });
  res.end(body);
});
srv.keepAliveTimeout = 65000;
srv.listen(port, "127.0.0.1", () => console.log("upstream-fast on", port));