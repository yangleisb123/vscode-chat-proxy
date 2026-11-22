// Blind-tunnel check: CONNECT through the proxy, then speak plain HTTP
// inside the tunnel. Usage: node connect-tunnel.mjs <proxyPort> <host> <port>
import net from "node:net";

const [proxyPort, host, port] = process.argv.slice(2);
const sock = net.connect(Number(proxyPort), "127.0.0.1");
let stage = 0;
let buf = "";
sock.on("connect", () => {
  sock.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`);
});
sock.on("data", (d) => {
  buf += d.toString("latin1");
  if (stage === 0) {
    const idx = buf.indexOf("\r\n\r\n");
    if (idx < 0) return;
    const head = buf.slice(0, idx);
    console.log("TUNNEL-HEAD:", head.split("\r\n")[0]);
    if (!head.includes("200")) {
      console.log("FAIL: tunnel not established");
      process.exit(1);
    }
    stage = 1;
    buf = buf.slice(idx + 4);
    sock.write(
      `GET /v1/models HTTP/1.1\r\nHost: ${host}:${port}\r\nConnection: close\r\n\r\n`,
    );
  }
  if (stage === 1 && buf.includes("\r\n\r\n")) {
    const [head, body] = buf.split("\r\n\r\n");
    console.log("INNER-STATUS:", head.split("\r\n")[0]);
    console.log("INNER-BODY:", body.slice(0, 80));
    sock.end();
    process.exit(0);
  }
});
sock.on("error", (e) => {
  console.log("SOCKET-ERROR:", e.message);
  process.exit(1);
});
setTimeout(() => {
  console.log("TIMEOUT");
  process.exit(1);
}, 10000);