# Handoff — where this stands

You are taking over the MyHumans.App iPad shell. This file is what to read first; `README.md` is
what it is and how the bridge works, and `MAINTAINING.md` answers "which repo do I change?".

The original version of this file was written before any of it had run. That is no longer the
situation, so it has been rewritten rather than annotated: everything below describes what is
built, shipped and in daily use.

---

## 1. State, honestly

| | |
|---|---|
| Compiles | **Yes** — CI on every push (public repo, so unlimited minutes) and locally on Xcode 26.6 |
| Runs on a device | **Yes** — iPad Air 11-inch (M3), iPadOS 26.5 |
| Signed / installable | **Yes** — paid Individual team `W6Q5F68ZAQ`, profile good for a year |
| Apple Pencil | **Yes** — Pencil Pro, in real coaching notes |
| Sign-in | **Yes** — email/password AND Microsoft, both inside the web view |
| The bolt-on | **Landed** — `myhumansapp` #254, #258, and everything after |
| Live for real work | **Yes** — Josh writes real notes on it |

The one thing that has never been done: nobody but Josh has used it. There is no TestFlight, no
second device, no other coach.

---

## 2. What it actually is now

A `WKWebView` pointed at `myhumans.app`, plus **one native screen** — a PencilKit canvas that
embeds INSIDE the take-notes page at a rectangle the page measures and reports.

That inline design is the whole shape of the thing, and it was arrived at by use:

- Fullscreen-only writing meant losing the person's details at the exact moment they were being
  written about, so the canvas moved into the page.
- Fullscreen now just grows the same rectangle. Same paper, two sizes, no modal and no "Done".
- The page renders the chrome — the tool row, undo/redo/delete — because a native canvas cannot
  be styled to match the app around it, and Apple's tool palette cannot be sized at all.

**Bridge v2**, capability `ink-inline`. A v1 shell or a v1 web app still gets the original
full-screen modal flow; both sides degrade rather than break. See `README.md` for the messages.

---

## 3. The rules that cost something when broken

Every one of these was learned the hard way, most of them from a bug that reached the device.

- **Nothing expensive runs while the pen is down.** An autosave that rasterised the page from
  inside the drawing callback dropped strokes — the stall starves PencilKit's touch delivery and
  iOS cancels the live stroke. Timers only, and the picture is rendered rarely.
- **Ask an ink what width it accepts.** Every `PKInkingTool.InkType` has a `validWidthRange` and
  silently pins anything past it. Two rounds of tool sizes looked broken because of this — four
  slots collapsing onto one width, with no error anywhere.
- **Sizes live in the page**, one table per tool, and are not multiples of each other. The shell
  applies what it is told and clamps; it must never compute a width for a tool it was not given
  one for. A Pencil squeeze doing exactly that produced a 1.5pt eraser.
- **Every message carries a `session` tag** — the page's draft key. A flush crosses the bridge
  asynchronously, and an in-app navigation can mount the NEXT person's canvas before it lands.
  Delivering by recency put one coach's handwriting into another person's record.
- **The recovery copy is keyed by that same draft key**, never by note id. A brand-new note has
  no id until the page's first commit, so keying by id filed every new note under one shared
  slot and offered it to whoever opened a blank page next.
- **The draft is written BEFORE the commit**, every time. `commit()` returns early when offline,
  and until that message arrives the drawing lives in the native canvas and nowhere else.
- **A drawing that fails to decode disables saving and tells the page.** An empty page that
  saves overwrites real handwriting with nothing.
- **The web app must work with no shell**, and the shell must tolerate any web version. An
  unrecognised message is ignored, never thrown.
- **Never replace the user agent; only append.** tldraw's iOS guards key off a bare
  `/iPad|iPhone/` match, and nothing on either side may branch on the UA.

---

## 4. Open loops

Nothing is broken. These are the things a next session would pick up.

1. **Two review angles never ran.** The adversarial review of the inline canvas lost its
   Swift/geometry and race-condition lenses to a usage limit mid-run. Everything they would have
   covered is live and working, but unreviewed — and every round that *did* run found something
   real. This is the highest-value thing left.
2. **Offline mode.** Agreed in principle, deferred deliberately. Josh is offline at a client
   site once or twice a week. The design conversation is done: cache everything for the ~50
   people he coaches, handwriting images for the last three months, queue writes and replay them
   on reconnect, and show a note that was recovered from offline the first time it is opened.
   Only ever his iPad, so last-write-wins is a correct rule rather than a compromise.
3. **Launch screen** is still Apple's default. The app icon is done.
4. **Nobody else has used it.** A second coach means TestFlight, which the paid account now
   allows.

---

## 5. Do not do these

- **Do not put app features in the shell.** Every screen belongs to the web app so it stays
  shared with desktop and Android. If you find yourself writing a settings screen in Swift, stop.
  The canvas-settings menu that briefly existed here was removed for exactly this reason.
- **Do not upgrade or touch tldraw** in the other repo. Pinned to an exact version because
  upgrading is a one-way door for saved handwriting.
- **Do not copy anything from `myhumansapp` into this repo.** This one is PUBLIC. It holds no
  secrets, no customer data and no server code, and it needs to stay that way.
- **Do not restore handwriting to the browser.** The tldraw canvas still works there, and that
  is the problem: it works badly enough that a coach who lands on it writes a glitchy note and
  cannot tell why.

---

## 6. Working agreements

- Branch and PR for anything non-trivial, in both repos. CI gates both.
- Josh is not a coder. Keep chat replies short and jargon-free, and end with a numbered table of
  anything you need from him. The `myhumansapp` repo's `CLAUDE.md` has the full house style.
- **Check what a checkout is pointed at before quoting it.** A stale local checkout of
  `myhumansapp` — 120 commits behind, on a branch whose remote was deleted — produced a
  confident, wrong "correction" that survived review in two repositories.
- Behaviour on a device cannot be verified any other way. Do not report something as working
  because it compiles.

---

## 7. Answered, so nobody re-opens them

- **Does the Pencil beat the web canvas?** Yes, decisively. Palm rejection is a non-event;
  reported as indistinguishable from Apple Notes.
- **Is a full-screen writing page right?** No — and that is why the canvas is inline, with
  fullscreen as a size rather than a mode.
- **Is the $99 account needed?** It is bought and active. Certificates last a year instead of
  seven days.
