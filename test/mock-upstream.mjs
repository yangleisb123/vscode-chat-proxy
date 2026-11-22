// Mock upstream API server for end-to-end proxy tests.
// Usage: node test/mock-upstream.mjs [port]
import http from 'node:http';

const port = Number(process.argv[2] || 18080);

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const url = req.url.split('?')[0];
    if (req.method === 'POST' && url.endsWith('/v1/chat/completions')) {
      let parsed = null;
      try { parsed = JSON.parse(body.toString('utf8')); } catch {}
      if (parsed && parsed.stream) {
        res.writeHead(200, {
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
        });
        const sys = parsed.messages?.find((m) => m.role === 'system');
        const sysText = typeof sys?.content === 'string'
          ? sys.content
          : JSON.stringify(sys?.content ?? null);
        let i = 0;
        const timer = setInterval(() => {
          i++;
          res.write(`data: {"seq":${i},"system":${JSON.stringify(sysText)}}\n\n`);
          if (i >= 3) {
            clearInterval(timer);
            res.write('data: [DONE]\n\n');
            res.end();
          }
        }, 100);
      } else {
        const out = JSON.stringify({
          received: parsed,
          seenHeaders: {
            host: req.headers.host,
            connection: req.headers.connection,
            'content-length': req.headers['content-length'],
            authorization: req.headers.authorization ?? null,
          },
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(out);
      }
    } else {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        passthrough: true,
        method: req.method,
        url: req.url,
        body: body.toString('utf8'),
      }));
    }
  });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`mock upstream listening on 127.0.0.1:${port}`);
});