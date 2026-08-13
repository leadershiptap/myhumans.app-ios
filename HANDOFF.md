# Handoff — picking this up on a Mac

You are taking over the MyHumans.App iPad shell. Everything in this repo was written on a Linux
machine with no Xcode, so **the code compiles but has never run.** Your job is the part that
needs real hardware.

Read `README.md` for what this is and `web/BOLT-ON.md` for how it eventually joins the web app.
This file is what to do first.

---

## 1. State, honestly

| | |
|---|---|
| Compiles | **Yes** — GitHub's macOS 15 / Xcode 16 runners every push, and locally on Xcode 26.6 |
| Bridge logic tested | **Yes** — 21 Vitest tests in `web/`, green in CI |
| Ever run on a device | **Yes** — 13 Aug 2026, iPad Air (`iPad15,3`) |
| Ever run in the simulator | **Yes** — iPad Pro 11-inch, bridge injection confirmed |
| Apple Pencil verified | **Yes** — see §3c below |
| Sign-in / auth verified | **No** — §3a is the remaining go/no-go |
| Signed / installable | **Yes** — free personal team `W6Q5F68ZAQ`, 7-day profile |
| Touches the `myhumansapp` repo | **No, and must not yet** — see §6 |

Treat anything about *behaviour* below as a prediction unless §3 marks it verified. Anything about
*structure* is verified.

### Verified on device, 13 Aug 2026

§3c passed in full on an iPad Air with an **Apple Pencil Pro**. Palm rejection is a non-event —
resting a hand on the glass while writing produced no stray marks and no dropped strokes. Reopen
returns strokes still editable, not a flattened picture. Undo/redo, the tool picker, finger
scrolling while holding the Pencil, Clear, and Done-on-blank all behaved. Reported as
indistinguishable from Apple Notes.

**That answers open question 1 in §8: the Pencil premise holds.** The WebKit limitation quoted in
`README.md` is gone by construction, as predicted.

§3a (sign-in, and the Microsoft-in-a-web-view risk) and §3b (whole-app smoke) are still untested.

---

## 2. Get it running (first 30 minutes)

```bash
git clone https://github.com/leadershiptap/myhumans.app-ios
cd myhumans.app-ios
open MyHumans.xcodeproj
```

1. Target **MyHumans** → **Signing & Capabilities** → set **Team** to Josh's Apple ID.
   A free Apple ID is enough. If the bundle id `com.leadershiptap.myhumans` is taken, change it —
   nothing depends on it.
2. Plug in the iPad, pick it as the destination, Run.
3. On the iPad: **Settings → General → VPN & Device Management** → trust the developer cert.

A free Apple ID install stops working after 7 days; plug in and re-run. That is expected and is
why no paid account has been bought yet.

**`Config.startTarget` decides what loads.** It ships as `.harness`.

---

## 3. What only a device can answer

Work these in order. The first is the one that could change the whole plan.

### 3a. Auth — the go/no-go

Set `Config.startTarget = .liveApp`, run, and answer:

- Does sign-in complete inside the web view? Clerk is configured for **email + password OR
  Office 365**. Email and password should be fine. **Microsoft may refuse to authenticate inside
  an embedded web view** — that is the known risk.
- Force-quit the app, reopen. Are you still signed in? (Cookies are on
  `WKWebsiteDataStore.default()`, so they should persist. Verify it.)
- Settings → connect a calendar. The Microsoft OAuth redirect is the same exposure.

**If Microsoft refuses:** do not fight it. Two acceptable answers, in order —
(1) sign in with email and password on the iPad, which already works and costs nothing;
(2) route only the OAuth hop through `ASWebAuthenticationSession`. Do not disable web security,
do not spoof a Safari user agent to get around it, and do not replace the user agent at all
(see §5).

### 3b. Whole-app smoke, still on `.liveApp`

Drive every screen. Dashboard, people, a profile, interactions, tasks, follow-ups, the resource
library, settings. You are looking for anything the web view breaks that a browser does not:
fixed positioning, the `h-dvh` layout, safe areas, the sidebar, dialogs, file pickers, mailto
links. Log what you find; most of it will be small.

### 3c. The Pencil — the whole reason this exists

Set `Config.startTarget = .harness`, run, and use the buttons on the page.

- **Palm rejection.** Rest your hand on the glass and write. This is the failure the web canvas
  could never fix, so it is the acceptance test. `drawingPolicy = .pencilOnly` should make it a
  non-event.
- **Latency and feel** against the web canvas at `myhumans.app` on the same iPad. If it does not
  feel obviously better, say so plainly — the entire project rests on it.
- **Scrolling** with fingers while the Pencil is in hand. The page grows as you approach the
  bottom (`growContentIfNeeded`); check it does not fight you.
- **The tool picker.** Does it land somewhere sensible, and can it be moved?
- **Undo / Redo** in the nav bar. These were wired to the wrong undo manager once already.
- **Reopen.** Write, tap Done, tap "Reopen last drawing". The strokes must come back editable.
  This is the round trip the whole design depends on.
- **The returned picture.** The harness shows it. Check it is not transparent, not cropped, and
  a sane size — it logs kilobytes for both the drawing and the picture.
- **Clear** → confirms → `ink.discard` in the log.
- **Done on a blank page** → `ink.close` with `EMPTY` in the log, deliberately.

Watch the log panel throughout. Every bridge message prints there.

---

## 4. Then: the things worth building next

Only after §3, and only what the device actually showed you a need for.

1. Fix whatever §3 surfaced. Expect layout and sizing, not architecture.
2. **A page-length model that matches how coaches write.** Right now the page grows by a screen
   at a time. Real use may want fixed pages, or a much taller one.
3. **Backgrounding.** If iOS kills the app mid-note, the drawing lives in the native canvas and
   nowhere else until an autosave crosses the bridge. Consider persisting the `PKDrawing` to
   disk on `sceneDidEnterBackground` and restoring it. This matters more once it is on the live
   app, where a lost note is a real note.
4. **A launch screen and an app icon.** Both are placeholders.
5. Only then, the bolt-on in `web/BOLT-ON.md` — and **not before the Postgres migration in the
   `myhumansapp` repo has cut over.**

---

## 5. Rules — do not undo these

Each is either load-bearing or was already fixed once.

- **Never replace the user agent; only append to it** (`applicationNameForUserAgent` in
  `Config.swift`). tldraw's own iOS guards key off a bare `/iPad|iPhone/` user-agent match that
  iPadOS Safari already fails, so changing the UA changes which of its internal guards fire. The
  web app feature-detects the shell through the injected object, never the UA.
- **The bridge is four messages, and unknown ones are ignored rather than thrown.** The web app
  must keep working with no shell present, and this shell must tolerate a newer web app. If you
  need a fifth message, that is fine — but bump `Bridge.version` and add a capability string, do
  not assume both sides ship together.
- **A drawing that fails to decode disables saving and sends nothing.** It renders as an empty
  page, and an empty page that saves overwrites real handwriting with nothing.
- **An empty page never sends content**, but `ink.close` still fires carrying `isEmpty` so the
  web page learns the screen closed. Erasing everything is not a request for a blank note;
  deleting is what Clear is for.
- **The exported PNG has the page colour composited in.** PencilKit returns a transparent image;
  the web canvas exports with a background, and every surface in the app renders that picture.
- **A very long page steps the export scale down rather than cropping.** Cropping silently loses
  handwriting, and `/api/upload-image` refuses anything over 15MB.
- **This app never fetches an ink image.** Every ink URL is a cookie-authenticated same-origin
  request; staying out of that path is what keeps this shell from needing its own copy of the
  app's auth.
- **The native canvas never talks to the database or Cloudinary.** Drawing in, drawing and
  picture out. All persistence belongs to the web app.

---

## 6. Do not do these

- **Do not change anything in the `myhumansapp` repo.** It is frozen for an Airtable → Postgres
  migration and this work is deliberately separate until that has cut over. `web/` in this repo
  is where the eventual web-side code lives in the meantime.
- **Do not add app features to the shell.** Every screen belongs to the web app so it stays
  shared with desktop and Android. If you find yourself writing a settings screen or a people
  list in Swift, stop.
- **Do not upgrade or touch tldraw** in the other repo. It is pinned to an exact version because
  upgrading is a one-way door for saved handwriting.
- ~~**Do not buy the $99 Apple Developer account yet.**~~ Overtaken by events — Josh bought it on
  13 Aug 2026. It is **not yet reaching Xcode**: the profile issued on that date is a free personal
  team (`W6Q5F68ZAQ`, "Joshua Hartsell", 7-day expiry), so the 7-day reinstall still applies. Likely
  an unsigned agreement at developer.apple.com or a membership still processing. Not blocking §3.

---

## 7. Working agreements

- Branch and PR for anything non-trivial; CI runs the simulator build and the bridge tests on
  every push and pull request.
- Josh is not a coder. Keep chat replies short and jargon-free, and end with a numbered table of
  anything you need from him. The `myhumansapp` repo's `CLAUDE.md` has the full house style —
  worth reading even though you are not working in that repo.
- Behaviour on a device cannot be verified any other way. Do not report something as working
  because it compiles.

---

## 8. Open questions for Josh

Ask these when they come up, not up front:

1. Does the Pencil actually feel better than the web canvas? If not, the project's premise is
   wrong and it is better to know in week one.
2. Is a full-screen writing page right, or is losing the person's details beside it a problem in
   a real session?
3. How long should a note's page be before it becomes a second page?
