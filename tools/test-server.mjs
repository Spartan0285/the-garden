#!/usr/bin/env node
/*
 * test-server - the parts of the world the app talks to, on this Mac.
 *
 * Two jobs:
 *
 *   /files/<name>     serves build/catalog/testfiles/<name> slowly, with
 *                     Range, so a download takes long enough to watch it
 *                     queue, pause and resume on a real PowerPC Mac.
 *   /api/...          runs server/cloudflare/functions/api/{search,catalog,
 *                     reports}.js against a SQLite database shaped like D1,
 *                     so the endpoints can be exercised before they are
 *                     deployed anywhere.
 *
 * Point a test Mac at it with the app's own preferences:
 *   scripts/remote-run.sh pbg4 featured \
 *       GDSearchURL=http://<this Mac>:8099/api/search \
 *       GDReportsURL=http://<this Mac>:8099/api/reports
 *
 *   node tools/test-server.mjs [--port 8099] [--rate 500]   (rate: KB/s)
 */
import { createServer } from 'node:http';
import { createReadStream, statSync, mkdirSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const FILES = join(ROOT, 'build', 'catalog', 'testfiles');
const argv = Object.fromEntries(process.argv.slice(2).map((a, i, all) =>
  a.startsWith('--') ? [a.slice(2), all[i + 1]] : []).filter((x) => x.length));
const PORT = Number(argv.port || 8099);
const RATE = Number(argv.rate || 500) * 1024;      /* bytes per second */

mkdirSync(FILES, { recursive: true });

/* A D1-shaped wrapper around SQLite, enough for what the functions use. */
const db = new DatabaseSync(join(ROOT, 'build', 'catalog', 'test-index.sqlite'));
const stmt = (sql, args = []) => ({
  bind: (...a) => stmt(sql, a),
  run: async () => { db.prepare(sql).run(...args); return { success: true }; },
  all: async () => ({ results: db.prepare(sql).all(...args) }),
  first: async () => db.prepare(sql).get(...args) ?? null,
});
const env = {
  INDEX_DB: {
    prepare: (sql) => stmt(sql),
    batch: async (ss) => { for (const s of ss) await s.run(); return []; },
  },
};

const api = {};
for (const name of ['search', 'catalog', 'reports'])
  api[name] = await import(join(ROOT, 'server/cloudflare/functions/api', `${name}.js`));

createServer(async (req, res) => {
  const url = 'http://' + (req.headers.host || 'test') + req.url;
  const path = req.url.split('?')[0];

  if (path.startsWith('/files/')) {
    /* Named, never a path: nothing outside the test files is servable. */
    const file = join(FILES, basename(decodeURIComponent(path.slice(7))));
    let size;
    try { size = statSync(file).size; } catch { res.writeHead(404); return res.end('no\n'); }
    const range = /bytes=(\d+)-/.exec(req.headers.range || '');
    const from = range ? Number(range[1]) : 0;
    res.writeHead(range ? 206 : 200, {
      'content-type': 'application/octet-stream',
      'content-length': String(size - from),
      'accept-ranges': 'bytes',
      ...(range ? { 'content-range': `bytes ${from}-${size - 1}/${size}` } : {}),
    });
    console.log(`${req.method} ${path}${range ? ` (from ${from})` : ''} -> ${res.statusCode}`);
    const chunkSize = 64 * 1024;
    const pause = (chunkSize / RATE) * 1000;
    for await (const chunk of createReadStream(file, { start: from, highWaterMark: chunkSize })) {
      if (!res.write(chunk)) await new Promise((r) => res.once('drain', r));
      await new Promise((r) => setTimeout(r, pause));
    }
    return res.end();
  }

  const which = /^\/api\/(search|catalog|reports)/.exec(path);
  if (!which) { res.writeHead(404); return res.end('no\n'); }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const request = new Request(url, {
    method: req.method,
    headers: req.headers,
    body: chunks.length ? Buffer.concat(chunks) : undefined,
  });
  const mod = api[which[1]];
  const fn = req.method === 'POST' ? mod.onRequestPost : mod.onRequestGet;
  if (!fn) { res.writeHead(405); return res.end('no\n'); }
  const out = await fn({ request, env });
  console.log(`${req.method} ${req.url} -> ${out.status}`);
  res.writeHead(out.status, Object.fromEntries(out.headers));
  res.end(Buffer.from(await out.arrayBuffer()));
}).listen(PORT, () => {
  console.log(`listening on ${PORT}; files from ${FILES} at ${RATE / 1024} KB/s`);
});
