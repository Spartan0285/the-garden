# The feedback system, and how to put it in another app

One endpoint serves every app in this family. A report says which app it came
from, and the server labels the issue accordingly, so Captain Polliwog,
PowerEmu and anything after them share a single private repository and a
single Worker. Adding an app is a few lines, not a new deployment.

This is written for whoever is building the next one.

---

## 1. The shape of a report

`POST https://<host>/api/feedback`, `content-type: application/json`, with
`X-Feedback-Client: <client token>`.

```json
{
  "id":       "20260920T200144-3f9c1a72",
  "app":      "the-garden",
  "version":  "0.3",
  "build":    "7",
  "topic":    "Something is broken",
  "summary":  "Get button downloads the wrong file",
  "message":  "the whole description, as typed",
  "email":    "",
  "page":     "item /games/dark-castle",
  "system":   { "os": "10.4", "arch": "PowerPC", "model": "PowerBook3,4",
                "memoryMB": 640, "screen": "1024x768",
                "classic": true, "accelerator": "not in use" },
  "screenshot": "<base64 PNG, or empty>"
}
```

| Field | Required | What it is |
|---|---|---|
| `id` | yes | Stable for the life of the report, **including retries**. This is what stops one report becoming two issues. Generate it once, keep it in the queued file. |
| `app` | yes | Must be a key in `APPS` in `functions/api/feedback.js`, or the report is refused. |
| `version`, `build` | yes | Whatever the app calls itself. `build` is what an updater compares. |
| `topic` | yes | The reader's choice, **as words, not a code**. It becomes a `topic:` label, slugged. |
| `summary` | no | The issue title. Falls back to the first 90 characters of `message`. |
| `message` | yes | At least five characters, at most 20,000. |
| `email` | no | Empty unless they typed one. Never fill this in for them. |
| `page` | no | Where they were. Free text; make it mean something in *your* app. |
| `system` | no | Anything you like; the keys above are rendered into a table. |
| `screenshot` | no | Base64 PNG. Dropped silently if R2 is not configured. |

### Answers

| Status | Body | What the app should do |
|---|---|---|
| `200` | `{"ok":true,"issue":12}` | Done. Delete the queued copy. |
| `200` | `{"ok":true,"issue":12,"duplicate":true}` | Already had it. Same: delete the queued copy. |
| `400` | `{"error":"..."}` | Malformed or empty. Do **not** retry; it will never succeed. |
| `413` / `429` | | Too large, or too many. Keep it and try later. |
| `502` / `503` | `{"error":"...","stored":<bool>}` | The endpoint is unwell. Keep it and try later. `stored` says whether the server kept a copy - do not assume it did. |

---

## 2. Adding your app

1. **Pick an id**: lowercase, hyphenated, matching the repository name is
   easiest (`captain-polliwog`).
2. **Add it to `APPS`** in `functions/api/feedback.js`:
   ```js
   const APPS = {
     'the-garden': 'The Garden',
     'captain-polliwog': 'Captain Polliwog',
   };
   ```
   The value is the human name, used in the issue title.
3. **Deploy the site.** Nothing else changes: no new bucket, no new token, no
   new endpoint. Reports arrive labelled `app:captain-polliwog`.

That is the whole server side.

---

## 3. The window, and the words in it

The order matters more than the visual design. Someone reporting a problem is
already annoyed; every field they do not understand is a reason to give up.

1. **"What is this about?"** - a pop-up menu. Never a free-text category.
2. **"What happened?"** - one large box, focused when the window opens. This
   is the only field that matters; everything else is decoration around it.
3. **"Your email (only if you want an answer)"** - the parenthetical is doing
   real work. Without it people either leave it blank and wonder why nobody
   replied, or fill it in and wonder what else you will send them.
4. **"Include a picture of <the app>'s window"** - a checkbox with a **live
   thumbnail of exactly what would be sent**, next to it, at a size where the
   contents are recognisable.
5. **A plain sentence listing everything else that travels**, naming the
   actual values: version, build, the machine, the page. Not "diagnostic
   information".
6. **Send** and **Cancel**. Send is the default button.

### Two rules worth keeping

- **Show what you send, before you send it.** If a field cannot be shown in
  the window, it should not be in the report.
- **Never lose what someone wrote.** If the endpoint cannot be reached, write
  the report to an outbox on disk and send it at the next launch. A person who
  writes three paragraphs and gets "could not connect" does not write them
  again.

---

## 4. Choosing your topics

**This is the part to change, and the part most likely to be left alone.**

The topics are not a taxonomy of software defects. They are a list of the
things *your* app can disappoint someone with. A list copied from another app
produces reports filed under "Something else", which is the same as no topic
at all.

The Garden is a store, so its topics are about getting software and running it:

> Something is broken · A download would not install · The compatibility badge
> is wrong · Something looks wrong on screen · It was too slow · A suggestion ·
> Something else

A browser has nothing to install, and its failures are about pages:

> A page did not load · A page looked wrong · Something on the page did not
> work · It was too slow · It quit unexpectedly · A suggestion · Something else

An emulator's failures are about the guest and the hardware it pretends to be:

> The guest will not start · Graphics are wrong · No sound · A device is
> missing · It was too slow · It quit unexpectedly · A suggestion · Something
> else

When you write yours:

- **Name symptoms, not causes.** "A page did not load" is something a person
  can recognise. "Network layer error" is a guess they are not qualified to
  make, and often wrong.
- **Six or seven, and no more.** A longer list is read as a form to be
  completed rather than a question to be answered.
- **Always keep "A suggestion".** A good share of what arrives is not a bug,
  and people will not send it if every option says something is broken.
- **Always keep "Something else", last.** It is the honest escape hatch, and
  a pile of reports under it tells you your list is wrong.
- **Put the most common one first.** It is the default, and most people will
  not change it.

`page` deserves the same thought. In a store it is the item being looked at;
in a browser, the site (consider whether you should send it at all); in an
emulator, the guest and its configuration. Send whatever you would want to
know first when the report arrives.

---

## 5. Client checklist

- [ ] Report `id` generated once, and kept across retries
- [ ] Outbox on disk; send what is in it at launch
- [ ] Every field shown in the window before sending
- [ ] Screenshot optional, previewed, and of the app's window only
- [ ] The endpoint address overridable without a rebuild
- [ ] `400` does not retry; `5xx` does
- [ ] Nothing sent unless Send is pressed
