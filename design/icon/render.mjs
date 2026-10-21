// render.mjs — render icon.html in headless Chrome and save PNGs.
// Usage: node render.mjs out.png@variant=black&beam=1 [more jobs...]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const root = path.dirname(fileURLToPath(import.meta.url));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript' };
const server = http.createServer((req, res) => {
  const f = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!f.startsWith(root + path.sep) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) {
    res.writeHead(404);
    return res.end();
  }
  res.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  args: (process.env.CHROME_ARGS || '--ignore-gpu-blocklist --enable-gpu').split(' '),
});
try {
  const page = await browser.newPage();
  page.on('console', (m) => console.log('[page]', m.text()));
  page.on('pageerror', (e) => console.log('[pageerror]', e.message));
  for (const job of process.argv.slice(2)) {
    const at = job.indexOf('@');
    const out = job.slice(0, at), query = job.slice(at + 1);
    const t0 = Date.now();
    await page.goto(`http://127.0.0.1:${port}/icon.html?${query}`);
    await page.waitForFunction('window.__done || window.__err', { timeout: 180000 });
    const err = await page.evaluate('window.__err');
    if (err) throw new Error(err);
    const data = await page.evaluate('window.__png');
    fs.writeFileSync(out, Buffer.from(data.split(',')[1], 'base64'));
    console.log(`wrote ${out} (${query}) in ${Date.now() - t0} ms`);
  }
} finally {
  await browser.close();
  server.close();
}
