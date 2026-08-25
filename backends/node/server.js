// Zero-dependency Node backend (profile "node"): node's built-in http module,
// no package.json, no package manager, nothing to install.
'use strict';

const http = require('node:http');
const os = require('node:os');

const PORT = 8080;

const server = http.createServer((req, res) => {
  const path = req.url.split('?')[0];

  if (req.method === 'GET' && path === '/messages') {
    const body = JSON.stringify({
      backend: 'node',
      message: 'Hello from Node.js',
      host: os.hostname(),
      x_forwarded_proto: req.headers['x-forwarded-proto'] || null,
      x_forwarded_port: req.headers['x-forwarded-port'] || null,
      x_forwarded_for: req.headers['x-forwarded-for'] || null,
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(body);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found', path }));
});

server.listen(PORT, () => {
  console.log(`node backend listening on :${PORT}`);
});
