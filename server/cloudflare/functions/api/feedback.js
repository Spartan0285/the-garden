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
  const length = Number(request.headers.get('content-length') || 0);
  if (length > MAX_BODY) return json(413, { error: 'too large' });

  let body;
  try {
    body = await request.json();
  } catch (e) {
    return json(400, { error: 'not JSON' });
  }

  const app = String(body.app || '');
  if (!APPS[app]) return json(400, { error: 'unknown app' });

  const id = String(body.id || '').replace(/[^A-Za-z0-9._-]/g, '').slice(0, 64);
  if (!id) return json(400, { error: 'no id' });

  const message = String(body.message || '').slice(0, MAX_MESSAGE);
  if (message.trim().length < 5) return json(400, { error: 'empty report' });

  // --- already seen: the app is retrying something we took ----------------
  const seenKey = `issue:${app}:${id}`;
  const seen = env.SEEN ? await env.SEEN.get(seenKey) : null;
  if (seen) return json(200, { ok: true, issue: Number(seen), duplicate: true });

  // --- rate limit, per address --------------------------------------------
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  if (env.SEEN) {
    const hour = new Date().toISOString().slice(0, 13);
    const key = `rate:${ip}:${hour}`;
    const used = Number((await env.SEEN.get(key)) || 0);
    if (used >= RATE_PER_HOUR) return json(429, { error: 'too many reports' });
    await env.SEEN.put(key, String(used + 1), { expirationTtl: 7200 });
  }

  // --- keep it, before anything that can fail -----------------------------
  const received = new Date().toISOString();
  const record = { ...body, screenshot: undefined, received, ip };
  if (env.FEEDBACK) {
    await env.FEEDBACK.put(`reports/${app}/${id}.json`, JSON.stringify(record, null, 2), {
      httpMetadata: { contentType: 'application/json' },
    });
  }

  let shotPath = null;
  if (body.screenshot && env.FEEDBACK) {
    try {
      const bytes = base64ToBytes(body.screenshot);
      if (bytes.length > 0 && bytes.length < MAX_BODY) {
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
    // Stored, but nobody has been told. Tell the app so it tries again later.
    return json(503, { error: 'no issue tracker configured', stored: true });
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
    `| App | ${APPS[app]} ${body.version || '?'} (build ${body.build || '?'}) |`,
    `| Topic | ${body.topic || '-'} |`,
    `| Page | ${body.page || '-'} |`,
    `| System | Mac OS X ${sys.os || '?'}, ${sys.arch || '?'}, ${sys.model || '?'} |`,
    `| Memory | ${sys.memoryMB || '?'} MB |`,
    `| Screen | ${sys.screen || '?'} |`,
    `| Classic | ${sys.classic ? 'yes' : 'no'} |`,
    `| Accelerator | ${sys.accelerator || '-'} |`,
    `| Reply to | ${body.email ? body.email : '(not given)'} |`,
    `| Received | ${received} |`,
    `| Report | \`${id}\` |`,
  ];
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
    // It is safely in R2; the app will send it again and the id will match.
    return json(502, { error: 'could not open an issue', stored: true });
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
