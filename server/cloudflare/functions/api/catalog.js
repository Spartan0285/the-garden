/*
 * /api/catalog - rows that copies of the app have already fetched.
 *
 * The index behind /api/search cannot be crawled: macintoshgarden.org's
 * robots.txt says "Disallow: /", and when that was tested on 3 October 2026
 * the address was blocked at their firewall inside a minute.  Quite right.
 * So the index is built from pages people opened anyway - the app parses a
 * listing to show it, and offers the same rows here.  The site sees nothing
 * it did not already see, and sees less once search is answered from here.
 *
 *   POST /api/catalog
 *   content-type: text/tab-separated-values
 *
 *   #garden-rows<tab>1
 *   /games/dark-castle<tab>Dark Castle<tab>games<tab>1986<tab>Arcade<tab>...
 *
 * The answer is the number of rows taken, as a number on the first line,
 * because what reads it is a Mac OS X 10.4 application with no JSON parser.
 *
 * Nothing identifying is accepted, stored or logged here: no id, no session,
 * no account, no address beyond what the rate limit needs for an hour.  A row
 * is a line of a public catalogue.
 */

const MAX_BODY = 256 * 1024;
const MAX_ROWS = 500;
const COLS = ['path', 'title', 'list', 'year', 'category', 'author', 'rating', 'votes', 'thumb', 'blurb'];

const PATH_RE = /^\/(apps|games)\/[A-Za-z0-9][A-Za-z0-9._%-]{0,120}$/;
/* A thumbnail is shown by the app, so it may only be the Garden's own. */
const THUMB_RE = /^https?:\/\/([a-z0-9-]+\.)*macintoshgarden\.org\/[^\s"']*$/i;

const SCHEMA = `CREATE TABLE IF NOT EXISTS titles (
  path TEXT PRIMARY KEY, title TEXT NOT NULL, list TEXT, year TEXT,
  category TEXT, author TEXT, rating REAL, votes INTEGER, thumb TEXT,
  blurb TEXT, seen INTEGER NOT NULL DEFAULT 1, updated TEXT
)`;

/* Control characters out, length capped, tabs already gone by the split. */
function clean(s, max) {
  return String(s || '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

function parseRow(line) {
  const f = line.split('\t');
  const row = {};
  for (let i = 0; i < COLS.length; i++) row[COLS[i]] = f[i] || '';
  row.path = clean(row.path, 140);
  if (!PATH_RE.test(row.path)) return null;
  row.title = clean(row.title, 200);
  if (!row.title) return null;
  row.list = row.path.startsWith('/games/') ? 'games' : 'apps';
  row.year = clean(row.year, 20);
  row.category = clean(row.category, 120);
  row.author = clean(row.author, 120);
  const rating = Number(row.rating);
  row.rating = Number.isFinite(rating) && rating > 0 && rating <= 5 ? rating : 0;
  const votes = parseInt(row.votes, 10);
  row.votes = Number.isFinite(votes) && votes > 0 && votes < 1000000 ? votes : 0;
  row.thumb = clean(row.thumb, 400);
  if (row.thumb && !THUMB_RE.test(row.thumb)) row.thumb = '';
  row.blurb = clean(row.blurb, 160);
  return row;
}

function reply(status, n, note) {
  return new Response(`${n}\n${note ? note + '\n' : ''}`, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  });
}

export async function onRequestPost({ request, env }) {
  if (env.CLIENT_TOKEN && request.headers.get('x-garden-client') !== env.CLIENT_TOKEN)
    return reply(403, 0, 'no');
  if (!env.INDEX_DB)
    return reply(501, 0, 'no index database here');

  const length = Number(request.headers.get('content-length') || 0);
  if (length > MAX_BODY) return reply(413, 0, 'too much at once');

  const body = await request.text();
  if (body.length > MAX_BODY) return reply(413, 0, 'too much at once');
  if (!body.startsWith('#garden-rows')) return reply(400, 0, 'not rows');

  /* An hour's worth of batches from one address, so a single copy cannot
   * rewrite the catalogue on its own.  The address is the key and nothing
   * else: it expires with the counter and is never stored with a row. */
  if (env.SEEN) {
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';
    const key = `catalog-rate:${ip}:${Math.floor(Date.now() / 3600000)}`;
    const used = Number(await env.SEEN.get(key)) || 0;
    if (used >= 40) return reply(429, 0, 'enough for now');
    await env.SEEN.put(key, String(used + 1), { expirationTtl: 7200 });
  }

  const rows = [];
  const seen = new Set();
  for (const line of body.split('\n')) {
    if (!line || line.startsWith('#')) continue;
    if (rows.length >= MAX_ROWS) break;
    const row = parseRow(line);
    if (!row || seen.has(row.path)) continue;
    seen.add(row.path);
    rows.push(row);
  }
  if (!rows.length) return reply(200, 0);

  await env.INDEX_DB.prepare(SCHEMA).run();

  /* Anyone can post here, so what an established row says cannot be changed
   * by posting something else.  A title, once learned, is never rewritten -
   * software released in 1986 does not get renamed, and this is the whole of
   * the defence against one batch defacing the catalogue.  The other text is
   * filled in when it is missing and left alone when it is not, so a thin row
   * (the feed knows a title and nothing else) completes a row without being
   * able to damage one.  Only the numbers and the thumbnail, which are
   * checked and bounded, follow the most recent report. */
  const sql = `INSERT INTO titles (path, title, list, year, category, author, rating, votes, thumb, blurb, seen, updated)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1, ?11)
    ON CONFLICT(path) DO UPDATE SET
      list     = excluded.list,
      year     = CASE WHEN titles.year     = '' THEN excluded.year     ELSE titles.year     END,
      category = CASE WHEN titles.category = '' THEN excluded.category ELSE titles.category END,
      author   = CASE WHEN titles.author   = '' THEN excluded.author   ELSE titles.author   END,
      rating   = CASE WHEN excluded.rating    > 0  THEN excluded.rating   ELSE titles.rating   END,
      votes    = CASE WHEN excluded.votes     > 0  THEN excluded.votes    ELSE titles.votes    END,
      thumb    = CASE WHEN excluded.thumb    <> '' THEN excluded.thumb    ELSE titles.thumb    END,
      blurb    = CASE WHEN titles.blurb = '' THEN excluded.blurb ELSE titles.blurb END,
      seen     = titles.seen + 1,
      updated  = excluded.updated`;

  const now = new Date().toISOString().slice(0, 10);   /* a day, not a moment */
  const stmt = env.INDEX_DB.prepare(sql);
  await env.INDEX_DB.batch(rows.map((r) => stmt.bind(
    r.path, r.title, r.list, r.year, r.category, r.author, r.rating, r.votes, r.thumb, r.blurb, now)));

  return reply(200, rows.length);
}

/* What is in there, for anyone who wants to know before switching it on. */
export async function onRequestGet({ env }) {
  if (!env.INDEX_DB) return reply(501, 0, 'no index database here');
  await env.INDEX_DB.prepare(SCHEMA).run();
  const r = await env.INDEX_DB.prepare(
    'SELECT COUNT(*) AS n, MAX(updated) AS last FROM titles').first();
  return new Response(JSON.stringify({ titles: r?.n || 0, updated: r?.last || null }, null, 1),
    { headers: { 'content-type': 'application/json; charset=utf-8' } });
}
