# Adding an app to the family

Three things every Cytrus Software app for Mac OS X 10.4 and 10.5 should have,
and how to put them in the next one:

1. **Feedback** that reaches one private issue tracker, shared by every app
   (sections 1-6).
2. **An About window** that says what the app is, what it is not, and that it
   is an alpha (section 7).
3. **Links that open in a browser able to load them** - which on these systems
   is not the one the Mac came with (section 8).

The endpoint is already deployed and already serves every app; adding one is a
few lines, not a new deployment. The About window and the link policy are
about seventy lines each and can be copied from The Garden.

Written for whoever is building the next one.

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
| `id` | yes | Stable for the life of the report, **including retries**. This is what stops one report becoming two issues. Generate it once, keep it in the queued file. It must also be **unguessable** &mdash; see below. |
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

## 5. The report id has to be unguessable

The screenshot attached to a report is served from `/api/shot/<app>/<id>.png`
with no authentication. It has to be: the GitHub issue embeds that address, and
the bucket itself stays private. So the id is the only thing standing between
one person's screenshot and anybody who asks for it.

Use at least 64 bits from a seeded generator:

```c
[NSString stringWithFormat:@"%@-%08x%08x", timestamp,
    (unsigned)arc4random(), (unsigned)arc4random()]
```

**Not `random()` or `rand()`.** Neither seeds itself. Without an `srandom()`
call they return the same sequence on every machine and every launch &mdash;
the first value is always `6b8b4567` &mdash; which leaves the timestamp as the
entire secret, and a timestamp is a day's worth of guesses. The Garden shipped
this bug and it was fixed on 2026-09-20; don't reintroduce it in the next app.
`arc4random` seeds itself from the kernel and needs no setup.

## 6. Client checklist

- [ ] Report `id` generated once, kept across retries, and **from a seeded CSPRNG**
- [ ] Outbox on disk; send what is in it at launch
- [ ] Every field shown in the window before sending
- [ ] Screenshot optional, previewed, and of the app's window only
- [ ] The endpoint address overridable without a rebuild
- [ ] `400` does not retry; `5xx` does
- [ ] Nothing sent unless Send is pressed

---

## 7. The About window

`orderFrontStandardAboutPanel:` cannot carry any of what follows, so each app
draws its own. The Garden's is `src/GDAbout.m`; about a hundred and fifty
lines, and most of it is the text.

### What goes in it, in this order

1. **The app's icon, its name, `Version X (build N)`, and a stage badge.**
   The build number matters: it is what an updater compares and what a
   feedback report carries, so it is what you will ask someone for.
2. **A rule**, then **the alpha sentence in bold**: *"This is an alpha build.
   Expect rough edges, and please say when you find one."* An invitation, not
   a disclaimer - it is the sentence that turns an annoyed person into a
   reporter.
3. **What the app is not.** Any app that reads somebody else's archive has to
   say so plainly and early. The Garden's first line is that it is not
   affiliated with the Macintosh Garden. Do not bury this at the bottom.
4. **Who made it** - one paragraph, first person, and keep it first person all
   the way through. Mixing *"I hope you like it"* with *"his other projects"*
   reads like a press release someone forgot to finish.
5. **The Cytrus Software lockup.**
6. **The two buttons.**

### Marking the stage in one place

    Makefile:  STAGE = Alpha
      -> Info.plist: GDBuildStage = @STAGE@
        -> the About badge
        -> the window title:  "Featured - The Garden (Alpha)"
        -> the version in every feedback report

Emptying `STAGE` removes it from all of them, with no other edit. Whatever you
do, do not write "Alpha" into `CFBundleShortVersionString`: an updater compares
build numbers, but the version string ends up in file names, tags and signed
statements, and a space in it will find every one of them.

### The two buttons, and their colours

Lime `#A8D81A` for cytrusretro.com, purple `#6F2E7E` for amcreativecoach.com -
the lime is from the site, the purple is sampled from the app's own icon.

**Pick the text colour from the fill, not by habit.** Lime takes near-black
(`#1A2A00`); purple takes white. White on lime is unreadable on a CRT, and
these are CRTs.

NSButton will not fill itself with an arbitrary colour on 10.4, so the button
draws itself:

```objc
@interface GDColorButton : NSButton { NSColor *fill, *ink; }
@end

- (void)drawRect:(NSRect)dirty {
    NSRect r = NSInsetRect([self bounds], 0.5, 0.5);
    NSColor *c = [[self cell] isHighlighted]        // NSButton has no -isHighlighted
        ? [fill blendedColorWithFraction:0.25 ofColor:[NSColor blackColor]] : fill;
    [c set];  [GDRoundRect(r, 6) fill];
    // ... then the title, centred, in `ink`
}
```

Both buttons go through the link policy in section 8. Neither calls
`openURL:` directly.

### Brand artwork, on a Mac from 2005

Use **`images/cytruslogo.png`** from the website repository, scaled to the size
you actually draw it (The Garden ships it at 240x63 and draws it at 240x63; a
bigger file only costs a G3 the downscale). `Resources/cytruslogo.png`.

**Do not rasterise `cytruslogo.svg` yourself.** Its wordmark is set in *Ariana
Pro*, which no Mac here has and probably no Mac you build on has either, so the
render comes out as the lemon beside a row of tiny fallback glyphs. Nothing
warns you; it just looks wrong, and it looks wrong in a way you will not notice
until it is on a screen in front of someone. The PNG is the exported artwork
with the real typeface baked in, which is why it is the one to ship.

One more: a view that draws top-down (`isFlipped` returning `YES`) positions
its **subviews** top-down as well. A button placed at `y = 24` lands at the
top of the window, over the icon. Measure it from the bottom yourself.

---

## 8. Linking out to the web

**Every app in this family except Captain Polliwog should do this.**

An About box or a help link that calls `openURL:` sends someone to the browser
their Mac came with. Safari 4 on Tiger and Safari 5 on Leopard stop at TLS 1.0,
which almost nothing accepts now, so the link does not open a page - it opens a
failure, in another application, with no explanation. Cytrus Retro's own site
is among the sites that will refuse it.

Captain Polliwog is a browser for 10.4 and 10.5 that can reach a modern site.
So a link should ask, rather than assume:

| Situation | What happens |
|---|---|
| Polliwog is already the default browser | Open it. Say nothing. |
| Polliwog is installed, but not the default | Offer it first: **Open in Captain Polliwog** / Open in My Browser / Cancel |
| Polliwog is not installed | Recommend it: **Get Captain Polliwog** / Open in My Browser / Cancel |

The reader's own browser is always on the panel. The recommendation is the
default button, never the only button - someone may well have TenFourFox or
Aquafox set up and know exactly what they are doing.

`src/GDWebLink.m` in The Garden is about seventy lines and can be copied
wholesale; only `GDPolliwogPage` needs changing. The pieces:

```objc
// installed?
[[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:
    @"org.captainpolliwog.browser"]

// the default browser?
LSCopyDefaultHandlerForURLScheme(CFSTR("http"))      // compare, case-insensitively

// open a URL in it
[[NSWorkspace sharedWorkspace] openURLs:[NSArray arrayWithObject:url]
                withAppBundleIdentifier:@"org.captainpolliwog.browser"
                                options:NSWorkspaceLaunchDefault
         additionalEventParamDescriptor:nil launchIdentifiers:NULL];
```

One wrinkle worth knowing: **"Get Captain Polliwog" cannot send them to their
browser either** - that is the whole problem. Show the download page in the
app's own web view, which has the bundled TLS. Recommending a browser by
opening a page that will not load is not a recommendation.

While you are there, put the answers in the report:

```json
"system": { "browser": "Safari", "polliwog": true }
```

The server renders any `system` key it does not already know about, so this
costs nothing on the endpoint. Knowing that someone is on Safari 4 explains a
class of report by itself.
