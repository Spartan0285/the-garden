/*
 * /api/reports - did it actually run?
 *
 * The badge on a download ("Compatible with Mac OS X", "via Rosetta", "with
 * Classic") is worked out from two lines of the Garden's own page and what
 * this Mac is.  It is a good guess and it is still a guess.  This is where
 * the guess meets the world: someone who installed a title says whether it
 * ran, and the next person sees "Ran for 12 people on a PowerPC Mac, Mac OS X
 * 10.4" next to our opinion.
 *
 *   POST /api/reports        one line: path, variant, host, 1 or 0
 *   GET  /api/reports?path=/games/dark-castle
 *
 * Only counts are kept - a row per (title, variant, host, outcome) with a
 * number on it.  There is no record of a report, so there is nothing to tie
 * two of them together, and nothing to tie any of them to a person.  A report
 * is only ever sent because someone pressed Yes or No; nothing is collected
 * in the background.
 */

const MAX_BODY = 4096;
const PATH_RE = /^\/(apps|games)\/[A-Za-z0-9][A-Za-z0-9._%-]{0,120}$/;
/* Exactly what GDCompat's hostDescription produces, and nothing else. */
const HOST_RE = /^(PowerPC|Intel) Mac, Mac OS X 10\.[0-9](, Classic)?$/;

const SCHEMA = `CREATE TABLE IF NOT EXISTS reports (
  path TEXT NOT NULL, variant TEXT NOT NULL, host TEXT NOT NULL,
  ok INTEGER NOT NULL, n INTEGER NOT NULL DEFAULT 0, updated TEXT,
  PRIMARY KEY (path, variant, host, ok)
)`;

const clean = (s, max) =>
  String(s || '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);

function text(status, body) {
  return new Response(body, {
    status,
    headers: { 'content-type': 'text/tab-separated-values; charset=utf-8', 'cache-control': 'no-store' },
  });
}

export async function onRequestPost({ request, env }) {
  if (env.CLIENT_TOKEN && request.headers.get('x-garden-client') !== env.CLIENT_TOKEN)
    return text(403, '0\n');
  if (!env.INDEX_DB) return text(501, '0\nno index database here\n');
  if (Number(request.headers.get('content-length') || 0) > MAX_BODY)
    return text(413, '0\n');

  const body = await request.text();
  if (body.length > MAX_BODY || !body.startsWith('#garden-report'))
    return text(400, '0\nnot a report\n');

  const line = body.split('\n').find((l) => l && !l.startsWith('#'));
  if (!line) return text(400, '0\nempty\n');
  const f = line.split('\t');
  const path = clean(f[0], 140);
  const variant = clean(f[1], 120);
  const host = clean(f[2], 60);
  const ok = f[3] && f[3].trim() === '1' ? 1 : 0;
  if (!PATH_RE.test(path) || !HOST_RE.test(host))
    return text(400, '0\nnot a report\n');

  /* One person pressing a button a hundred times is not a hundred people. */
  if (env.SEEN) {
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';
    const key = `report-rate:${ip}:${Math.floor(Date.now() / 3600000)}`;
    const used = Number(await env.SEEN.get(key)) || 0;
    if (used >= 30) return text(429, '0\nenough for now\n');
    await env.SEEN.put(key, String(used + 1), { expirationTtl: 7200 });
    /* And the same answer about the same thing is one answer, not two. */
    const once = `report-once:${ip}:${path}:${variant}`;
    if (await env.SEEN.get(once)) return text(200, '0\nalready counted\n');
    await env.SEEN.put(once, '1', { expirationTtl: 180 * 24 * 3600 });
  }

  await env.INDEX_DB.prepare(SCHEMA).run();
  await env.INDEX_DB.prepare(
    `INSERT INTO reports (path, variant, host, ok, n, updated) VALUES (?1, ?2, ?3, ?4, 1, ?5)
     ON CONFLICT(path, variant, host, ok) DO UPDATE SET n = reports.n + 1, updated = excluded.updated`)
    .bind(path, variant, host, ok, new Date().toISOString().slice(0, 10)).run();

  return text(200, '1\n');
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const path = clean(url.searchParams.get('path'), 140);
  if (!PATH_RE.test(path)) return text(400, '#garden-reports\t1\t\n');
  if (!env.INDEX_DB) return text(200, `#garden-reports\t1\t${path}\n`);

  await env.INDEX_DB.prepare(SCHEMA).run();
  const q = await env.INDEX_DB.prepare(
    'SELECT variant, host, ok, n FROM reports WHERE path = ?1 ORDER BY n DESC LIMIT 60')
    .bind(path).all();

  const lines = [`#garden-reports\t1\t${path}`];
  for (const r of q.results || [])
    lines.push([r.variant, r.host, r.ok, r.n].join('\t'));
  return new Response(lines.join('\n') + '\n', {
    headers: {
      'content-type': 'text/tab-separated-values; charset=utf-8',
      'cache-control': 'public, max-age=600',
    },
  });
}
