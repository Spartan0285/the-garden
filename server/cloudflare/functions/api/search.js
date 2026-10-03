/*
 * /api/search - the catalogue index, searched at the edge.
 *
 * The app used to ask the Garden's own Drupal search: a token fetch, a form
 * POST, a page of HTML, and a relevance order that put "The Dark Hills of
 * Cherai" above "Dark Castle".  Twenty seconds on a Pismo, and nothing at all
 * on the day the site answered 502 to everything.  This answers the same
 * question from one table in a few kilobytes.
 *
 * The table is built by tools/garden-index.mjs and is a plain TSV, because
 * what reads it is a Mac OS X 10.4 application with no JSON parser: splitting
 * on tabs is a line of code there, and parsing JSON is not.
 *
 *   GET /api/search?q=dark+castle          titles matching, best first
 *   GET /api/search?q=...&list=games       one listing only
 *   GET /api/search?q=...&limit=100        up to 200, default 60
 *   GET /api/search?format=json            the same thing, for a browser
 *   GET /api/search?q=...&since=<ISO>      nothing unless the index is newer
 *
 * The index is whichever of these there is, in order: the INDEX_DB database
 * that /api/catalog fills from what copies of the app have read, the CATALOG
 * R2 binding, or a /catalog/catalog.tsv.gz sitting on the site - so this
 * works on a plain Pages project with nothing configured at all.
 */

const INDEX_KEY = 'catalog/catalog.tsv.gz';
const INDEX_PATH = '/catalog/catalog.tsv.gz';
const REFRESH_MS = 10 * 60 * 1000;
const MAX_LIMIT = 200;

/* Parsed once per isolate and kept for as long as it lives. */
let cache = null;        /* { rows, built, at } */
let loading = null;

const COLS = ['path', 'title', 'list', 'year', 'category', 'author', 'rating', 'votes', 'thumb', 'blurb'];

/* Lowercase, strip accents and punctuation: "Müller's Quest!" -> "mullers quest".
 * Done once per row at load, and once per query. */
function fold(s) {
  return (s || '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function parseIndex(tsv) {
  const rows = [];
  let built = '';
  for (const line of tsv.split('\n')) {
    if (!line) continue;
    if (line.startsWith('#garden-index')) { built = line.split('\t')[2] || ''; continue; }
    if (line.startsWith('#')) continue;
    const f = line.split('\t');
    if (f.length < 3) continue;
    const row = {};
    for (let i = 0; i < COLS.length; i++) row[COLS[i]] = f[i] || '';
    row._title = fold(row.title);
    row._who = fold(row.category + ' ' + row.author + ' ' + row.year);
    row._blurb = fold(row.blurb);
    /* What a crowd thinks, flattened: a 5-star title with four votes should
     * not outrank a 4-star one with four hundred. */
    const votes = Number(row.votes) || 0;
    row._weight = (Number(row.rating) || 0) * Math.log10(1 + votes);
    rows.push(row);
  }
  return { rows, built, at: Date.now() };
}

async function loadIndex(env, request) {
  if (cache && Date.now() - cache.at < REFRESH_MS) return cache;
  if (loading) return loading;
  loading = (async () => {
    /* The contributed index, when there is one.  Read whole and kept for as
     * long as this isolate lives: a few thousand rows is nothing to hold, and
     * scoring them costs less than a round trip to the database would. */
    if (env && env.INDEX_DB) {
      const q = await env.INDEX_DB.prepare(
        `SELECT ${COLS.join(', ')} FROM titles ORDER BY path LIMIT 60000`).all();
      if (q.results && q.results.length) {
        cache = parseIndex([`#garden-index\t1\t${new Date().toISOString()}\t${q.results.length}`]
          .concat(q.results.map((r) => COLS.map((c) => String(r[c] ?? '')).join('\t')))
          .join('\n'));
        return cache;
      }
    }
    let tsv = null;
    if (env && env.CATALOG) {
      const obj = await env.CATALOG.get(INDEX_KEY);
      if (obj) tsv = await new Response(obj.body.pipeThrough(new DecompressionStream('gzip'))).text();
    }
    if (tsv === null) {
      const res = await fetch(new URL(INDEX_PATH, request.url), {
        cf: { cacheTtl: 600, cacheEverything: true },
      });
      if (!res.ok) throw new Error(`no index (HTTP ${res.status})`);
      /* fetch() undoes content-encoding, but not a .gz body. */
      const body = res.headers.get('content-encoding')
        ? res.body : res.body.pipeThrough(new DecompressionStream('gzip'));
      tsv = await new Response(body).text();
    }
    cache = parseIndex(tsv);
    return cache;
  })().finally(() => { loading = null; });
  return loading;
}

function score(row, query, tokens) {
  const t = row._title;
  let s = 0;
  if (t === query) s += 1000;
  else if (t.startsWith(query + ' ')) s += 600;
  else if (t.includes(query)) s += 400;

  let inTitle = 0, anywhere = 0;
  for (const tok of tokens) {
    const re = new RegExp('(^| )' + tok.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    if (re.test(t)) { s += 90; inTitle++; anywhere++; }
    else if (t.includes(tok)) { s += 35; inTitle++; anywhere++; }
    else if (re.test(row._who)) { s += 25; anywhere++; }
    else if (row._blurb.includes(tok)) { s += 8; anywhere++; }
  }
  if (!anywhere) return 0;
  if (inTitle === tokens.length && tokens.length > 1) s += 250;
  return s + row._weight;
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const q = (url.searchParams.get('q') || '').slice(0, 120);
  const list = url.searchParams.get('list');
  const format = url.searchParams.get('format');
  const limit = Math.min(MAX_LIMIT, Math.max(1, Number(url.searchParams.get('limit')) || 60));

  let index;
  try {
    index = await loadIndex(env, request);
  } catch (err) {
    /* Say so plainly: the app falls back to the Garden's own search. */
    return new Response(`#garden-search\t1\terror\t${err.message}\n`, {
      status: 503,
      headers: { 'content-type': 'text/tab-separated-values; charset=utf-8' },
    });
  }

  /* A client that already has this index wants nothing back. */
  const since = url.searchParams.get('since');
  if (since && index.built && since >= index.built)
    return new Response(null, { status: 304 });

  const query = fold(q);
  const tokens = query.split(' ').filter(Boolean);
  let hits = [];
  if (tokens.length) {
    for (const row of index.rows) {
      if (list && row.list !== list) continue;
      const s = score(row, query, tokens);
      if (s > 0) hits.push([s, row]);
    }
    hits.sort((a, b) => b[0] - a[0] || a[1].title.localeCompare(b[1].title));
    hits = hits.slice(0, limit);
  }

  const headers = {
    'content-type': format === 'json'
      ? 'application/json; charset=utf-8'
      : 'text/tab-separated-values; charset=utf-8',
    'cache-control': 'public, max-age=300',
    'x-index-built': index.built,
  };
  if (format === 'json') {
    return new Response(JSON.stringify({
      built: index.built, count: hits.length, total: index.rows.length,
      results: hits.map(([s, r]) => ({ score: Math.round(s), ...Object.fromEntries(COLS.map((c) => [c, r[c]])) })),
    }, null, 1), { headers });
  }
  const lines = [`#garden-search\t1\t${index.built}\t${hits.length}`, `#${COLS.join('\t')}`];
  for (const [, r] of hits) lines.push(COLS.map((c) => r[c]).join('\t'));
  return new Response(lines.join('\n') + '\n', { headers });
}
