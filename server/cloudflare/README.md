# The endpoints

*Putting this, the About window and the link policy into another app:
[docs/ADDING-AN-APP.md](../../docs/ADDING-AN-APP.md).*

One endpoint, on your own domain, for every app in this family. The site stays
static: Cloudflare Pages runs anything under `functions/` as a real endpoint on
the same hostname, on the free plan.

    functions/api/feedback.js        POST a report
    functions/api/shot/[[path]].js   GET a report's screenshot
    functions/api/search.js          GET the catalogue index, searched
    functions/api/catalog.js         POST rows for it; GET how many there are
    functions/api/reports.js         POST "it ran" / "it did not"; GET the counts

Copy both into the repository your Pages site is built from, keeping the
`functions/api/...` paths. Nothing else about the site changes.

## The search index

The Garden's own search is a Drupal form - a session, a form token, a POST, a
page of HTML - and it is the first thing to go when the site is unwell; on
3 October 2026 it answered 502 for a day, and the app could not search at all.
`/api/search` answers the same question from one table, in a few kilobytes of
tab-separated text, because what reads it is a Mac OS X 10.4 application with
no JSON parser.

    GET /api/search?q=dark+castle          best first, 60 at a time
    GET /api/search?q=...&list=games       one listing only
    GET /api/search?q=...&format=json      the same thing, readable

**Where the rows come from.** Not from a crawl. macintoshgarden.org's
robots.txt is `User-agent: * / Disallow: /`, and when that was tested - 27
pages, one at a time, 1.5 s apart, with a user agent saying who we were - the
whole address was blocked at their firewall within a minute, which cost every
Mac here the Garden, the app included. That is the site's answer and it is a
fair one. `tools/garden-index.mjs` still exists but refuses to run.

So the rows come from copies of the app: when someone opens a listing page,
which the app fetches to show it, the parsed rows are offered to
`/api/catalog`. The site sees exactly the traffic it already saw, and less of
it once searching stops going there.

It is **off until it is switched on** (Settings → The Shared Search Index),
because what a copy sends still says something about which pages were opened
on that Mac. What is sent is a public catalogue row - path, title, year,
category, author, rating, thumbnail, first line - with no identifier of any
kind, no account, no session, no timestamp of the app's making, in a batch
shuffled out of reading order, and never for a search result, only a listing.
Nothing is queued on disk between launches, so there is no record of browsing
anywhere to be read later.

**What the server will take.** A path has to look like `/apps/x` or
`/games/x`; a thumbnail has to be on macintoshgarden.org; text is capped and
stripped of control characters; a batch is at most 500 rows and 256 KB, and
one address may send 40 batches an hour. A title, once learned, is never
rewritten - 1986 software does not get renamed, and that is what stops one
batch defacing the catalogue. The other text fills a gap and never replaces
what is there; the rating, the vote count and the thumbnail follow the latest
report, being bounded and checked. Each row counts how many times it has been
seen, so a row nobody else has confirmed is visible as such.

`/api/search` reads the `INDEX_DB` database when there is one, then a
`CATALOG` R2 bucket, then `/catalog/catalog.tsv.gz` on the site itself, so it
works on a plain Pages project with nothing configured - it just has nothing
to say until something fills it.

    D1 → Create database, e.g. `garden-index`, and bind it as `INDEX_DB`.

The app's two addresses are preferences, so either can be moved, or switched
off entirely with an empty string:

    defaults write org.macintoshgarden.store GDSearchURL  https://example.com/api/search
    defaults write org.macintoshgarden.store GDCatalogURL ""

## Did it actually run?

The badge on a download is worked out from the Garden's "Architecture:" line,
the file's "For ..." line and what this Mac is. It is a good guess and it
stays a guess until somebody runs the thing. So a title you have installed
asks, once, whether it ran, and the item page shows what the answers add up
to - "Ran for 12 people on a Mac like yours" - beside our opinion.

    POST /api/reports    one line: path, file, host, 1 or 0
    GET  /api/reports?path=/games/dark-castle

Only counts are kept: a row per (title, file, host, outcome) with a number on
it. There is no record of an individual answer, so there is nothing to tie
two of them together and nothing to tie any of them to a person. `host` has
to be exactly what the app's own `hostDescription` produces ("PowerPC Mac,
Mac OS X 10.4, Classic") and is rejected otherwise, so it cannot be used to
carry something else. Nothing is ever sent without Yes or No being pressed.
One address may send 30 answers an hour, and the same answer about the same
title counts once for six months.

    defaults write org.macintoshgarden.store GDReportsURL ""   # off entirely

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

## What a report contains

Everything below is shown in the app's own window before anything is sent, and
nothing is sent unless Send is pressed. There is no background collection.

| Field | What it is | Example |
|---|---|---|
| `id` | names this report, so a retry is not a second issue | `20260920T200144-3f9c1a72` |
| `app` | which app in the family | `the-garden` |
| `version`, `build` | the app's version and build number | `0.2.4`, `6` |
| `topic` | what they chose from the pop-up | `Something is broken` |
| `summary` | the first line, for the issue title | first 90 characters |
| `message` | what they typed | free text |
| `email` | **only if they typed one**; empty otherwise | `` |
| `page` | the page they were on | `item /games/dark-castle` |
| `system.os` | the system version | `10.4` |
| `system.arch` | PowerPC or Intel | `PowerPC` |
| `system.model` | `hw.model` | `PowerBook5,4` |
| `system.memoryMB` | memory | `1536` |
| `system.screen` | the main screen | `1024x768` |
| `system.classic` | whether Classic is usable | `false` |
| `system.accelerator` | whether PowerEmu's accelerator is in use | `not in use` |
| `screenshot` | **only if the box is ticked**: the Garden's own window, PNG, longest edge 800 | |

The screenshot is of the Garden's window only, never the whole screen - but
that window can be showing the Library, which is a list of what they have
installed. The box is there to be switched off.

The server adds two things of its own to the copy it keeps in R2:
`received` (a timestamp) and `ip` (the address the report came from, used for
the rate limit). **The address is not put in the issue** - only in the stored
record.

What is never collected: the catalogue they have browsed, anything about other
software on the Mac, a serial number, an account name, or any identifier that
persists between reports.

## Setting it up

1. **A private repository for the reports**, e.g. `Spartan0285/feedback`.
   It holds no code; it is somewhere to triage. Keep it private: reports carry
   screenshots of people's screens and, when they offer one, an email address.

2. **A token.** GitHub → Settings → Developer settings → Fine-grained tokens.
   Give it *only* that repository, and only **Issues: read and write**. Nothing
   else, and no other repository.

3. **A Pages project**, with an R2 bucket and a KV namespace:
   - Workers & Pages → Create → Pages → connect the repository the site is
     built from. No build command; the output directory is wherever
     `functions/` sits (the repository root, for a plain static site).
   - R2 → Create bucket, e.g. `feedback`.
   - Workers & Pages → KV → Create namespace, e.g. `feedback-seen`.

   Both are optional to begin with: with no `FEEDBACK` binding the issue is
   still opened, just with no screenshot; with no `SEEN` binding there is no
   rate limit and no protection against a retry becoming a second issue. Start
   without them if you want to see it work, then add them.

4. **In the Pages project** (Settings → Functions / Environment variables):

   | Name | Kind | Value |
   |---|---|---|
   | `FEEDBACK` | R2 bucket binding | a bucket, e.g. `feedback` |
   | `SEEN` | KV namespace binding | a namespace, e.g. `feedback-seen` |
   | `GITHUB_TOKEN` | secret | the token from step 2 |
   | `GITHUB_REPO` | variable | `Spartan0285/feedback` |
   | `CLIENT_TOKEN` | secret, optional | must equal the app's `X-Feedback-Client` |

5. **The domain.** Pages project → Custom domains → Set up a custom domain →
   `www.cytrusretro.com`. The zone is already in the same Cloudflare account,
   so the DNS record is made for you. It has to be **www**, because that is
   what the app asks for - or change `GDFeedbackURL` in the app to match.

6. **Check it**, once deployed:

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
