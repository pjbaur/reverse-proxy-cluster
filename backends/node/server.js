// Zero-dependency Node backend (profile "node"): node's built-in http module,
// no package.json, no package manager, nothing to install.
// GET /messages accepts ?delay=<ms> (clamped 0-10000): the response is held
// for that many milliseconds so a balancer demo can keep one member busy.
'use strict';

const http = require('node:http');
const os = require('node:os');
const crypto = require('node:crypto');

const PORT = 8080;
// ROUTE, when set (sticky profile), is baked into the session cookie so the
// proxy balancer can pin the client to this member (jvmRoute-style).
const route = process.env.ROUTE || null;

const server = http.createServer((req, res) => {
  const path = req.url.split('?')[0];
  const params = new URL(req.url, 'http://localhost').searchParams;
  // absent / non-numeric / negative -> 0; capped at 10 s so a typo can't hang anything
  const delayMs = Math.min(Math.max(parseInt(params.get('delay'), 10) || 0, 0), 10000);

  if (req.method === 'GET' && path === '/messages') {
    const headers = { 'Content-Type': 'application/json' };
    if (route) {
      headers['Set-Cookie'] = `SESSIONID=${crypto.randomUUID()}.${route}; Path=/`;
    }
    const body = JSON.stringify({
      backend: 'node',
      message: 'Hello from Node.js',
      host: os.hostname(),
      x_forwarded_proto: req.headers['x-forwarded-proto'] || null,
      x_forwarded_port: req.headers['x-forwarded-port'] || null,
      x_forwarded_for: req.headers['x-forwarded-for'] || null,
    });
    setTimeout(() => {
      res.writeHead(200, headers);
      res.end(body);
    }, delayMs);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found', path }));
});

server.listen(PORT, () => {
  console.log(`node backend listening on :${PORT}`);
});
