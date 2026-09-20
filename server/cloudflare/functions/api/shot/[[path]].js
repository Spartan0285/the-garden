/*
 * GET /api/shot/<app>/<id>.png - a report's screenshot.
 *
 * The R2 bucket stays private; this is the only way out of it, and it only
 * serves what is under screenshots/.  The issue body links here, so the
 * picture shows up in GitHub for whoever is reading the report.
 */
export async function onRequestGet({ params, env }) {
  const parts = Array.isArray(params.path) ? params.path : [params.path];
  const key = `screenshots/${parts.join('/')}`;

  if (!env.FEEDBACK || parts.some((p) => !p || p.includes('..'))) {
    return new Response('not found', { status: 404 });
  }
  const object = await env.FEEDBACK.get(key);
  if (!object) return new Response('not found', { status: 404 });

  return new Response(object.body, {
    headers: {
      'content-type': object.httpMetadata?.contentType || 'image/png',
      'cache-control': 'public, max-age=86400',
    },
  });
}
