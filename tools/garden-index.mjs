#!/usr/bin/env node
/*
 * garden-index - build the catalogue index the app searches.
 *
 * The Garden's own search is a Drupal form: a token fetch, a POST, a page of
 * HTML to parse, and a relevance order that puts "The Dark Hills of Cherai"
 * above "Dark Castle".  On a Pismo that is twenty seconds, and when the site
 * is down - as it was on 3 October 2026 - there is no search at all.  So the
 * listings are read once here, into one small table that an edge function can
 * search in a millisecond and answer in a few kilobytes.
 *
 * This reads the A-Z listings, which are pages of ten rows carrying everything
 * the index holds.  It is deliberately slow: one request at a time, a pause
 * between them, backing off when the site says to, and asking with the
 * validators from last time so an unchanged page costs a 304 and no body.
 *
 * DO NOT RUN THIS AGAIN WITHOUT THE GARDEN'S AGREEMENT.  Their robots.txt is
 * "User-agent: * / Disallow: /", and on 3 October 2026 a first run of this -
 * 27 pages, one at a time, 1.5 s apart, identifying itself - had the whole
 * address blocked at their firewall within a minute: every Mac on this network
 * lost the Garden, the app included.  The block is why --i-know is required.
 *
 *   node tools/garden-index.mjs                       # resume/refresh
 *   node tools/garden-index.mjs --full                # ignore the validators
 *   node tools/garden-index.mjs --lists=games --pages=5   # a taste of it
 *
 * Writes build/catalog/catalog.tsv (and .gz), and build/catalog/state.json so
 * the next run is cheap.  Nothing here touches the site's downloads.
 */
import { createWriteStream } from 'node:fs';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { gzip } from 'node:zlib';
import { promisify } from 'node:util';
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const gzipAsync = promisify(gzip);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'build', 'catalog');

/* The site identifies us by this, and can refuse it.  A crawler that will not
 * say who it is cannot be asked to stop. */
const UA = 'TheGardenIndexer/1.0 (+https://github.com/Spartan0285/the-garden; ' +
           'builds the search index for The Garden, a Mac OS X client)';

/* The two A-Z listings, and the pager each one answers to.  Games carries two
 * pagers and the A-Z block is the second, which is why its pages are "0,N". */
const LISTS = {
  apps:  { path: '/apps/all',  page: (n) => (n ? `?page=${n}` : '') },
  games: { path: '/games/all', page: (n) => (n ? `?page=0%2C${n}` : '') },
};

const argv = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(a);
  return m ? [m[1], m[2] ?? true] : [a, true];
}));
const HOST = argv.host || 'macintoshgarden.org';
const DELAY = Number(argv.delay ?? 1500);
const MAX_PAGES = Number(argv.pages ?? Infinity);
const WANTED = String(argv.lists || 'apps,games').split(',');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------------------------------------------------------- fetching */

/* The Garden's certificate expired on 2 October 2026.  A request that fails
 * for that reason alone is made again accepting it - the same bargain the app
 * strikes, and for the same reason: the alternative is not reaching the site. */
function get(path, validators = {}) {
  return new Promise((resolve, reject) => {
    const go = (insecure) => {
      const headers = {
        'user-agent': UA,
        'accept': 'text/html',
        'accept-encoding': 'gzip',
        ...(validators.etag ? { 'if-none-match': validators.etag } : {}),
        ...(validators.modified ? { 'if-modified-since': validators.modified } : {}),
      };
      const req = httpsRequest(
        { host: HOST, path, headers, rejectUnauthorized: !insecure, timeout: 45000 },
        (res) => {
          const chunks = [];
          res.on('data', (c) => chunks.push(c));
          res.on('end', async () => {
            let body = Buffer.concat(chunks);
            if (res.headers['content-encoding'] === 'gzip' && body.length) {
              const { gunzip } = await import('node:zlib');
              body = await promisify(gunzip)(body).catch(() => body);
            }
            resolve({
              status: res.statusCode,
              headers: res.headers,
              body: body.toString('utf8'),
            });
          });
        });
      req.on('timeout', () => req.destroy(new Error('timeout')));
      req.on('error', (err) => {
        if (!insecure && err.code === 'CERT_HAS_EXPIRED') return go(true);
        reject(err);
      });
      req.end();
    };
    go(false);
  });
}

/* ----------------------------------------------------------------- parsing */

const unescape = (s) => String(s ?? '')
  .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
  .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
  .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&nbsp;/g, ' ')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

const text = (html) => unescape(String(html ?? '').replace(/<[^>]*>/g, ' '))
  .replace(/\s+/g, ' ').trim();

/* One row of a listing, which is what the app's own parseListing reads. */
function parseRow(chunk) {
  const link = /<h2>\s*<a href="(\/(?:apps|games)\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/.exec(chunk);
  if (!link) return null;
  const row = {
    path: unescape(link[1]).replace(/\?.*$/, ''),
    title: text(link[2]),
    year: '', category: '', author: '', rating: '', votes: '', thumb: '', blurb: '',
  };
  const images = /<div class="images">([\s\S]*?)<\/div>/.exec(chunk);
  const img = images && /<img[^>]+src="([^"]+)"/.exec(images[1]);
  if (img) row.thumb = unescape(img[1]);

  const descr = /<div class="descr">([\s\S]*?)(?=<div class="(?:images|game-preview)"|$)/.exec(chunk);
  const body = descr ? descr[1] : chunk;
  const para = /<p[^>]*>([\s\S]*?)<\/p>/.exec(body);
  if (para) row.blurb = text(para[1]).slice(0, 140);

  for (const [, tr] of body.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/g)) {
    const label = /<strong>([\s\S]*?)<\/strong>/.exec(tr);
    if (!label) continue;
    const cells = [...tr.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((m) => m[1]);
    const value = text(cells[1] ?? '');
    const name = text(label[1]);
    if (name.startsWith('Category')) row.category = value;
    else if (name.startsWith('Year')) row.year = value.slice(0, 20);
    else if (name.startsWith('Author')) row.author = value.slice(0, 80);
    else if (name.startsWith('Rating')) {
      const avg = /average-rating[\s\S]*?<span[^>]*>([\d.]+)/.exec(tr);
      const n = /total-votes[\s\S]*?<span[^>]*>(\d+)/.exec(tr);
      if (avg) row.rating = avg[1];
      if (n) row.votes = n[1];
    }
  }
  return row;
}

function parseListing(html) {
  const parts = html.split('<div class="game-preview"');
  return parts.slice(1).map(parseRow).filter(Boolean);
}

/* The pager's highest page, so a run knows how far it has to go. */
function lastPage(html, list) {
  let max = 0;
  const re = list === 'games' ? /[?&]page=0(?:%2C|,)(\d+)/g : /[?&]page=(\d+)(?!%2C|,)/g;
  for (const m of html.matchAll(re)) max = Math.max(max, Number(m[1]));
  return max;
}

/* -------------------------------------------------------------------- main */

async function main() {
  if (!argv['i-know']) {
    console.error(
      'Refusing to crawl.\n\n' +
      "macintoshgarden.org's robots.txt disallows crawling, and a run of this on\n" +
      '3 October 2026 got this network blocked at their firewall within a minute.\n' +
      'Get their agreement first - or better, ask them for a database dump.\n\n' +
      'If you have it: --i-know\n');
    process.exit(2);
  }
  await mkdir(OUT, { recursive: true });
  const statePath = join(OUT, 'state.json');
  let state = { pages: {}, rows: {} };
  if (!argv.full) {
    try { state = JSON.parse(await readFile(statePath, 'utf8')); } catch { /* first run */ }
  }
  state.pages ||= {};
  state.rows ||= {};

  let fetched = 0, unchanged = 0, failed = 0;
  for (const list of WANTED) {
    const spec = LISTS[list];
    if (!spec) { console.error(`no such listing: ${list}`); continue; }
    let total = Infinity;
    for (let page = 0; page <= Math.min(total, MAX_PAGES - 1); page++) {
      const url = spec.path + spec.page(page);
      const was = state.pages[url] || {};
      let res;
      try {
        res = await get(url, was);
      } catch (err) {
        failed++;
        console.error(`  ${url}: ${err.message}`);
        if (failed > 20) { console.error('too many failures; stopping'); break; }
        await sleep(DELAY * 4);
        continue;
      }

      if (res.status === 429 || res.status >= 500) {
        /* The site is asking for room.  Give it some and come back. */
        const after = Number(res.headers['retry-after']) || 30;
        console.error(`  ${url}: HTTP ${res.status}, waiting ${after}s`);
        await sleep(after * 1000);
        page--;
        if (++failed > 20) break;
        continue;
      }
      if (res.status === 304) {
        unchanged++;
      } else if (res.status === 200) {
        fetched++;
        const rows = parseListing(res.body);
        if (!rows.length && page > 0) { total = page - 1; break; }
        for (const row of rows) state.rows[row.path] = { ...row, list };
        state.pages[url] = {
          etag: res.headers.etag || '',
          modified: res.headers['last-modified'] || '',
          count: rows.length,
        };
        if (total === Infinity) {
          total = lastPage(res.body, list);
          console.log(`${list}: ${total + 1} pages`);
        }
      } else {
        console.error(`  ${url}: HTTP ${res.status}`);
        failed++;
      }

      if ((page % 25) === 0)
        console.log(`  ${list} page ${page}/${Number.isFinite(total) ? total : '?'}` +
                    `  (${Object.keys(state.rows).length} titles)`);
      await sleep(DELAY);
    }
  }

  /* One table, sorted so the file is stable between runs and diffs small. */
  const paths = Object.keys(state.rows).sort();
  const cols = ['path', 'title', 'list', 'year', 'category', 'author', 'rating', 'votes', 'thumb', 'blurb'];
  const clean = (s) => String(s ?? '').replace(/[\t\r\n]+/g, ' ').trim();
  const lines = [`#garden-index\t1\t${new Date().toISOString()}\t${paths.length}`,
                 `#${cols.join('\t')}`];
  for (const p of paths) lines.push(cols.map((c) => clean(state.rows[p][c])).join('\t'));
  const tsv = lines.join('\n') + '\n';

  await writeFile(join(OUT, 'catalog.tsv.tmp'), tsv);
  await rename(join(OUT, 'catalog.tsv.tmp'), join(OUT, 'catalog.tsv'));
  await writeFile(join(OUT, 'catalog.tsv.gz'), await gzipAsync(tsv, { level: 9 }));
  await writeFile(statePath, JSON.stringify(state));

  console.log(`\n${paths.length} titles  ${(tsv.length / 1048576).toFixed(2)} MB ` +
              `(${((await gzipAsync(tsv, { level: 9 })).length / 1048576).toFixed(2)} MB gzipped)`);
  console.log(`fetched ${fetched}, unchanged ${unchanged}, failed ${failed}`);
  console.log(join(OUT, 'catalog.tsv'));
}

main().catch((err) => { console.error(err); process.exit(1); });
