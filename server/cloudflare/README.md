# The feedback endpoint

One endpoint, on your own domain, for every app in this family. The site stays
static: Cloudflare Pages runs anything under `functions/` as a real endpoint on
the same hostname, on the free plan.

    functions/api/feedback.js        POST a report
    functions/api/shot/[[path]].js   GET a report's screenshot

Copy both into the repository your Pages site is built from, keeping the
`functions/api/...` paths. Nothing else about the site changes.

## What a report becomes

1. The whole report is written to R2 first, so it survives everything after it.
2. The screenshot goes to R2 as well and is served back through
   `/api/shot/<app>/<id>.png`; the bucket itself stays private.
3. An issue is opened in **one private repository**, titled
   `[The Garden 0.2.4] <first line>` and labelled `app:the-garden` and
   `topic:...`. Several apps share that repository and are told apart by the
   label, so a second app needs nothing here but a line in `APPS`.

Every report carries an id that survives retries, and the id is remembered in
KV once an issue exists for it. An app that retries a report we already took
gets the same issue number back rather than filing a second one.

## Setting it up

1. **A private repository for the reports**, e.g. `Spartan0285/feedback`.
   It holds no code; it is somewhere to triage. Keep it private: reports carry
   screenshots of people's screens and, when they offer one, an email address.

2. **A token.** GitHub → Settings → Developer settings → Fine-grained tokens.
   Give it *only* that repository, and only **Issues: read and write**. Nothing
   else, and no other repository.

3. **In the Pages project** (Settings → Functions / Environment variables):

   | Name | Kind | Value |
   |---|---|---|
   | `FEEDBACK` | R2 bucket binding | a bucket, e.g. `feedback` |
   | `SEEN` | KV namespace binding | a namespace, e.g. `feedback-seen` |
   | `GITHUB_TOKEN` | secret | the token from step 2 |
   | `GITHUB_REPO` | variable | `Spartan0285/feedback` |
   | `CLIENT_TOKEN` | secret, optional | must equal the app's `X-Feedback-Client` |

4. **Check it**, once deployed:

       curl -i https://www.cytrusretro.com/api/feedback \
         -H 'content-type: application/json' \
         -H 'X-Feedback-Client: garden-client-1' \
         -d '{"id":"test-1","app":"the-garden","version":"0.2.4","build":"6",
              "topic":"A suggestion","summary":"hello","message":"a test report",
              "system":{"os":"10.4","arch":"PowerPC"}}'

   A `200` with an issue number means it is working. Send the same `id` again
   and you should get the same number back, with `"duplicate":true`.

## What it refuses

- anything whose `app` is not in `APPS`
- bodies over 3 MB, or a message under five characters
- more than ten reports an hour from one address
- a wrong `X-Feedback-Client`, when `CLIENT_TOKEN` is set

That last one is in the application binary, so it is not a secret: it keeps a
public endpoint from being the first thing a scanner finds, nothing more. The
rate limit is the real defence.

## When it is down

The app keeps a report it could not send in
`~/Library/Application Support/The Garden/Outbox` and tries again the next time
it starts. Nothing a person wrote is lost because the site was not up yet - so
this can be deployed after the app that talks to it.

## Somewhere else instead

The address is a preference, so it can be moved without a new build:

    defaults write org.macintoshgarden.store GDFeedbackURL https://example.com/api/feedback
