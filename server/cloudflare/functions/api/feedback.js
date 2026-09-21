/*
 * POST /api/feedback - the feedback endpoint for every app in this family.
 *
 * A Cloudflare Pages Function: drop this file into the site's repository at
 * functions/api/feedback.js and the path becomes a real endpoint on the same
 * domain.  The site itself stays static.
 *
 * What it does with a report:
 *   1. checks it is one of ours, and not absurdly large
 *   2. keeps the whole thing in R2, so nothing is lost even if step 4 fails
 *   3. puts the screenshot in R2 too, served back through /api/shot/<id>
 *      (the bucket stays private)
 *   4. opens an issue in one private repository, labelled with the app it
 *      came from, so several apps share one place
 *
 * A report carries its own id and is retried by the app until it is accepted,
 * so the id is what stops a retry becoming a second issue.
 *
 * Bindings and secrets (Pages > Settings):
 *   FEEDBACK        R2 bucket binding
 *   SEEN            KV namespace binding (dedupe and rate limiting)
 *   GITHUB_TOKEN    secret: a fine-grained token with Issues: read and write
 *                   on the feedback repository only
 *   GITHUB_REPO     e.g. Spartan0285/feedback   (private)
 *   CLIENT_TOKEN    optional: must match the app's X-Feedback-Client header
 */

const APPS = {
  'the-garden': 'The Garden',
  'captain-polliwog': 'Captain Polliwog',
  'poweremu': 'PowerEmu',
};

const MAX_BODY = 3 * 1024 * 1024;     // a report with a screenshot, generously
const MAX_MESSAGE = 20000;
const RATE_PER_HOUR = 10;             // per address

const json = (status, obj) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });

function slug(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 40);
}

// A value going into the metadata table. Newlines and pipes would let a
// reporter forge extra rows, so they are flattened rather than trusted.
function cell(value) {
  const text = String(value === undefined || value === null || value === '' ? '-' : value)
    .replace(/[\r\n]+/g, ' ')
    .replace(/\|/g, '\\|')
    .slice(0, 200);
  return text.trim() || '-';
}

// Only actual PNGs go in the bucket: whatever is stored here is served back
// from our own domain, so it should be the kind of file we say it is.
const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
function looksLikePNG(bytes) {
  return bytes.length > PNG_MAGIC.length && PNG_MAGIC.every((b, i) => bytes[i] === b);
}

// The full address is used for rate limiting, which expires in hours. What is
// kept beside the report is coarse: enough to recognise a pattern of abuse,
// not a record of where each person was sitting.
function coarseIP(ip) {
  if (!ip || ip === 'unknown') return 'unknown';
  if (ip.includes(':')) return ip.split(':').slice(0, 3).join(':') + '::/48';
  const p = ip.split('.');
  return p.length === 4 ? `${p[0]}.${p[1]}.${p[2]}.0/24` : 'unknown';
}

function base64ToBytes(b64) {
  const clean = String(b64).replace(/[^A-Za-z0-9+/=]/g, '');
  const binary = atob(clean);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

// Labels have to exist before an issue can carry them.
async function ensureLabel(env, name, color) {
  const url = `https://api.github.com/repos/${env.GITHUB_REPO}/labels`;
  const res = await fetch(url, {
    method: 'POST',
    headers: githubHeaders(env),
    body: JSON.stringify({ name, color }),
  });
  // 422 means it is already there, which is the usual case.
  if (!res.ok && res.status !== 422) {
    console.log('label', name, res.status, await res.text());
  }
}

function githubHeaders(env) {
  return {
    authorization: `Bearer ${env.GITHUB_TOKEN}`,
    accept: 'application/vnd.github+json',
    'x-github-api-version': '2022-11-28',
    'content-type': 'application/json',
    'user-agent': 'cytrusretro-feedback',
  };
}

export async function onRequestPost({ request, env }) {
  // --- is this one of ours, and a sane size -------------------------------
  if (env.CLIENT_TOKEN && request.headers.get('x-feedback-client') !== env.CLIENT_TOKEN) {
    return json(403, { error: 'unknown client' });
  }
  // content-length is whatever the caller says it is, and chunked requests
  // have none at all, so it is only a cheap early out. The size that counts is
  // the number of bytes that actually arrived.
  const claimed = Number(request.headers.get('content-length') || 0);
  if (claimed > MAX_BODY) return json(413, { error: 'too large' });

  const buf = await request.arrayBuffer();
  if (buf.byteLength > MAX_BODY) return json(413, { error: 'too large' });

  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(buf));
  } catch (e) {
    return json(400, { error: 'not JSON' });
  }

  const app = String(body.app || '');
  if (!APPS[app]) return json(400, { error: 'unknown app' });

  const id = String(body.id || '').replace(/[^A-Za-z0-9._-]/g, '').slice(0, 64);
  if (!id) return json(400, { error: 'no id' });

  const message = String(body.message || '').slice(0, MAX_MESSAGE);
  if (message.trim().length < 5) return json(400, { error: 'empty report' });

  // --- rate limit, per address --------------------------------------------
  // This runs before the dedupe lookup below, so guessing at ids is bounded by
  // the same budget as sending reports. The count is only spent on reports we
  // actually take, so an app retrying one report is not punished for it.
  //
  // Read-then-write is not atomic in KV, so a burst of simultaneous requests
  // can slip a little over the limit. Holding an exact count needs a Durable
  // Object; this is here to stop a flood, not to be a precise meter.
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  const rateKey = `rate:${ip}:${new Date().toISOString().slice(0, 13)}`;
  let used = 0;
  if (env.SEEN) {
    used = Number((await env.SEEN.get(rateKey)) || 0);
    if (used >= RATE_PER_HOUR) return json(429, { error: 'too many reports' });
  }

  // --- already seen: the app is retrying something we took ----------------
  const seenKey = `issue:${app}:${id}`;
  const seen = env.SEEN ? await env.SEEN.get(seenKey) : null;
  if (seen) return json(200, { ok: true, issue: Number(seen), duplicate: true });

  // A new report, so it counts against the budget.
  if (env.SEEN) {
    await env.SEEN.put(rateKey, String(used + 1), { expirationTtl: 7200 });
  }

  // --- keep it, before anything that can fail -----------------------------
  const received = new Date().toISOString();
  const record = { ...body, screenshot: undefined, received, ip: coarseIP(ip) };
  if (env.FEEDBACK) {
    await env.FEEDBACK.put(`reports/${app}/${id}.json`, JSON.stringify(record, null, 2), {
      httpMetadata: { contentType: 'application/json' },
    });
  }

  let shotPath = null;
  if (body.screenshot && env.FEEDBACK) {
    try {
      const bytes = base64ToBytes(body.screenshot);
      if (bytes.length < MAX_BODY && looksLikePNG(bytes)) {
        shotPath = `screenshots/${app}/${id}.png`;
        await env.FEEDBACK.put(shotPath, bytes, {
          httpMetadata: { contentType: 'image/png' },
        });
      }
    } catch (e) {
      console.log('screenshot', String(e));
    }
  }

  // --- and open the issue --------------------------------------------------
  if (!env.GITHUB_TOKEN || !env.GITHUB_REPO) {
    // Tell the app to try again later.  Whether anything was actually kept
    // depends on R2 being bound, and saying otherwise would be a lie the
    // client cannot check.
    return json(503, { error: 'no issue tracker configured', stored: Boolean(env.FEEDBACK) });
  }

  const sys = body.system || {};
  const origin = new URL(request.url).origin;
  const lines = [
    message,
    '',
    '---',
    '',
    `| | |`,
    `|---|---|`,
    `| App | ${APPS[app]} ${cell(body.version)} (build ${cell(body.build)}) |`,
    `| Topic | ${cell(body.topic)} |`,
    `| Page | ${cell(body.page)} |`,
    `| System | Mac OS X ${cell(sys.os)}, ${cell(sys.arch)}, ${cell(sys.model)} |`,
    `| Memory | ${cell(sys.memoryMB)} MB |`,
    `| Screen | ${cell(sys.screen)} |`,
    `| Classic | ${sys.classic ? 'yes' : 'no'} |`,
    `| Accelerator | ${cell(sys.accelerator)} |`,
  ];
  // Whatever else this app chose to send. Apps differ - a browser reports
  // things a store does not - and a field nobody renders is a field nobody
  // will look at.
  const KNOWN_SYS = ['os', 'arch', 'model', 'memoryMB', 'screen', 'classic', 'accelerator'];
  for (const key of Object.keys(sys)) {
    const value = sys[key];
    if (KNOWN_SYS.includes(key) || value === '' || value === null || value === undefined) continue;
    const label = key.charAt(0).toUpperCase() + key.slice(1).replace(/([A-Z])/g, ' $1');
    lines.push(`| ${cell(label)} | ${typeof value === 'boolean' ? (value ? 'yes' : 'no') : cell(value)} |`);
  }
  lines.push(
    `| Reply to | ${body.email ? cell(body.email) : '(not given)'} |`,
    `| Received | ${received} |`,
    `| Report | \`${id}\` |`,
  );
  if (shotPath) {
    lines.push('', `![screenshot](${origin}/api/shot/${app}/${id}.png)`);
  }

  const labels = [`app:${app}`, `topic:${slug(body.topic) || 'other'}`];
  await Promise.all([
    ensureLabel(env, labels[0], '1f6feb'),
    ensureLabel(env, labels[1], '8957e5'),
  ]);

  const title = `[${APPS[app]} ${body.version || '?'}] ${
    (body.summary || message).slice(0, 90) || 'Feedback'
  }`;

  const res = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/issues`, {
    method: 'POST',
    headers: githubHeaders(env),
    body: JSON.stringify({ title, body: lines.join('\n'), labels }),
  });

  if (!res.ok) {
    console.log('issue', res.status, await res.text());
    // The app will send it again and the id will match.
    return json(502, { error: 'could not open an issue', stored: Boolean(env.FEEDBACK) });
  }

  const issue = await res.json();
  if (env.SEEN) {
    await env.SEEN.put(seenKey, String(issue.number), { expirationTtl: 60 * 60 * 24 * 90 });
  }
  return json(200, { ok: true, issue: issue.number });
}

// So a browser visiting the path gets something sensible rather than a 404.
export async function onRequestGet() {
  return json(405, { error: 'POST a report here' });
}
