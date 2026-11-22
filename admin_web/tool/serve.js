// Petit serveur local pour tester l'administration web : node tool/serve.js  →  http://localhost:8088
const http = require('http'), fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..', 'build', 'web');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm',
  '.png': 'image/png', '.ico': 'image/x-icon', '.svg': 'image/svg+xml', '.otf': 'font/otf', '.ttf': 'font/ttf', '.css': 'text/css', '.bin': 'application/octet-stream' };
http.createServer((req, res) => {
  let p = path.normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^([\/]\.\.)+/, '');
  let f = path.join(root, p);
  if (!f.startsWith(root) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) f = path.join(root, 'index.html');
  res.writeHead(200, { 'Content-Type': types[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
}).listen(8088, () => console.log('Administration web : http://localhost:8088'));
