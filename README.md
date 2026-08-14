# MyHumans.App — iPad shell

A thin iPad app around the real web app at `myhumans.app`, whose **only** unique capability is a
native Apple Pencil canvas.

Everything else — every screen, all data, all permissions, every save path — belongs to the web
app and is shared with desktop and Android. Feature work ships to Render and appears here
instantly: no rebuild, no App Review. Only this shell needs a new binary, which should be
roughly never.

## Why this exists

`components/ink/TldrawNoteCanvas.tsx` in the `myhumansapp` repo is 984 lines, and about 600 of
them work around tldraw's pinch model, WebKit's palm/pen reclassification, coalesced events,
wedged state charts and z-index. It is still glitchy, and that file's own header says why:

> WebKit never delivered the pen-down (the platform's one-input-type-at-a-time limitation —
> palm owned the touch stream; **not fixable in JS**).

That is a WebKit limitation, not a tldraw bug, so no better web canvas fixes it. PencilKit
removes it by construction and runs the Pencil at roughly 9ms.

What PencilKit deletes, all of it free here:

| Web workaround | Here |
|---|---|
| Camera lock (`isLocked: true`) to defeat the pinch pathway | no pinch model to defeat |
| Hand-rolled two-finger pan + `constrainNotebookCamera()` | `PKCanvasView` *is* a `UIScrollView` |
| Coalesced-events mutation on `editor.root.children` | PencilKit owns the input pipeline |
| `recoverStuckInteraction()` + `pointercancel` filtering | no JS state chart to wedge |
| Tool dock — 6 named stops, drag grip, palm guard | `PKToolPicker` |
| Two-finger double-tap eraser, 9 hand-tuned thresholds | the Pencil's own double-tap |

## Requirements

- **Xcode 16 or newer** (the project uses file-system-synchronized groups, `objectVersion 77`)
- An iPad and an Apple Pencil
- iOS 16+ deployment target

You do **not** need a paid Apple Developer account to build and run this. Xcode installs onto
your own iPad with a free Apple ID; the app stops working after 7 days and you plug in and
reinstall. The $99/year account is only needed for TestFlight, for putting it on anyone else's
iPad, and for the eventual Apple Business Manager distribution.

## Running it

1. Open `MyHumans.xcodeproj`.
2. Select the **MyHumans** target → **Signing & Capabilities** → set **Team** to your Apple ID.
   Change the bundle identifier if Xcode says it is taken.
3. Plug in the iPad, select it as the run destination, press Run.
4. First run only: on the iPad, **Settings → General → VPN & Device Management** → trust your
   developer certificate.

### What it loads

`Config.startTarget` decides:

- `.harness` — the bundled `Resources/harness.html`. Drives all four bridge messages against a
  page we control, so the canvas and the whole handoff can be finished and verified **before the
  `myhumansapp` repo knows this shell exists**. This is the default.
- `.liveApp` — the real `myhumans.app`. Use this to exercise sign-in, session persistence across
  a force-quit, every screen, and the Microsoft calendar-connect redirect. All of that works with
  no change to the web repo; only the ink handoff needs the bolt-on.

There is deliberately no in-app switch — a debug toggle is one more thing that can be left in the
wrong position and ship.

> There is no localhost option and there cannot usefully be one: Clerk's production keys only
> resolve `myhumans.app`, so no authenticated page renders anywhere else. That constraint already
> governs the web repo.

### If Xcode refuses to open the project

The `.xcodeproj` here is hand-written. If it will not open, this takes two minutes:
**File → New → Project → iOS → App**, name it `MyHumans`, interface Storyboard, language Swift,
save it alongside this README, then delete the generated `ViewController.swift`,
`Main.storyboard` and `SceneDelegate.swift` and drag the `MyHumans` folder in. Nothing in the
code depends on the project file.

## The bridge

Four messages. That is the entire contract, and it is small on purpose — it is what makes it safe
for this to be a separate repo while the web app ships independently.

**Injected at document start**, before any page script runs:

```js
window.__myhumansNative = { version: 2, caps: ['ink', 'ink-inline'] }
```

**Web → native**, via `window.webkit.messageHandlers.myhumans.postMessage({ name, payload })`:

| Message | Payload |
|---|---|
| `ink.open` | `{ noteId, drawing: base64 \| null, title, darkMode, frame?, prefs? }` — with `frame` the canvas embeds in the page at that rect; without it, full screen (the v1 behaviour) |
| `ink.frame` | `{ frame }` — the page laid out again; move the inline canvas |
| `ink.prefs` | `{ twoFingerScroll?, lockZoom?, darkMode? }` — live settings changes |
| `ink.undo` / `ink.redo` | `{}` — the page's own buttons |
| `ink.finish` | `{}` — page is done with the canvas; shell flushes (`ink.close`) and tears down |
| `ink.clearCanvas` | `{}` — page already deleted the note; blank the canvas, reply with nothing |

**Native → web**, via `window.__myhumansNativeEmit(name, base64OfJSON)`:

| Message | Payload | When |
|---|---|---|
| `ink.autosave` | `{ noteId, drawing, png, format }` | debounced ~1.5s after the pen lifts |
| `ink.close` | `{ noteId, drawing, png, format }` | the coach tapped Done — this is the flush |
| `ink.discard` | `{ noteId }` | the coach cleared the page |

The payload is JSON, then base64. That hop exists so nothing has to escape quotes, newlines or
backslashes into a JS string literal — `png` and `drawing` are base64 blobs hundreds of kilobytes
long, and one escaping mistake there is a silent, intermittent data-loss bug.

### Two rules

1. **The web app must work with no shell present.** Every native path on that side sits behind a
   `hasNativeInk()` check, and the tldraw canvas is always the fallback.
2. **This shell must tolerate any web version.** An unrecognised message is ignored, never
   thrown. `version` and `caps` are how the web app feature-detects.

Rule 2 has a second reason: tldraw's own iOS guards key off `tlenv.isIos`, a bare
`/iPad|iPhone/` user-agent match that iPadOS Safari already fails. Whatever UA this shell
presents changes which of tldraw's internal guards fire — so the shell **appends** to the UA via
`applicationNameForUserAgent` rather than replacing it, and nothing on either side may branch on
the UA.

## What the bolt-on has to do

When this lands in the web app (one PR, after the Postgres cutover), the web side must:

- Feature-detect with `hasNativeInk()` and call `ink.open` instead of mounting `TldrawNoteCanvas`.
- On `ink.autosave`, **write the localStorage draft first**, then commit on its existing
  schedule. This is load-bearing: the app's offline guard skips the commit when there is no
  network, so if the draft is not written from this message, a force-quit while offline loses
  everything the coach wrote. The drawing lives in the native canvas and nowhere else until this
  message arrives.
- On `ink.close`, commit as final.
- On `ink.discard`, delete the saved record — the same thing Clear does on the web canvas today.
- Store `format` alongside the drawing, so a tldraw canvas never tries to open a PencilKit blob.
  A `pencilkit` note on the web renders its PNG read-only; a `tldraw` note in this shell falls
  back to the tldraw canvas in the web view.

No read path changes at all: ink is already rendered everywhere from a flattened PNG served
through `/api/notes/[id]/ink-image`, and PencilKit produces one just as tldraw does. No schema
change is needed for the drawing either — `updateInkNoteFields` and `compressSnapshot` take an
*opaque string*, gzip it and store it. Only the `format` discriminator is new.

## Things worth not undoing

- **`drawingPolicy = .pencilOnly` by default.** Every documented failure in this feature's
  history is a palm or a finger being mistaken for the pen. Fingers scroll, the Pencil writes.
  The toolbar carries a toggle for anyone without a Pencil to hand.
- **A drawing that fails to load disables saving.** It renders as an empty page, and an empty
  page that saves overwrites real handwriting with nothing. Same reason `didFailToLoad()` exists
  on the web canvas.
- **An empty page is never sent.** Erasing everything is not a request for a blank note.
- **The exported PNG has the page colour composited in.** PencilKit returns a transparent image;
  the web canvas exports with `background: true`, and the two have to agree or an iPad note shows
  as transparent-on-whatever wherever it appears.
- **A very long page steps the export scale down rather than cropping.** A smaller picture is
  cosmetic; a cropped one silently loses handwriting, and `/api/upload-image` refuses anything
  over 15MB.
- **This app never fetches an ink image.** Every ink URL is a cookie-authenticated same-origin
  request; staying out of that path is what keeps this shell from needing a second copy of the
  app's auth.

## Files

| File | What it is |
|---|---|
| `MyHumans/Bridge.swift` | The whole contract: names, payloads, injection, encoding |
| `MyHumans/WebShellViewController.swift` | The `WKWebView`, the message handler, popup + alert handling |
| `MyHumans/InkCanvasViewController.swift` | `PKCanvasView` + `PKToolPicker`, autosave, PNG export |
| `MyHumans/Config.swift` | What to load, timings, export limits |
| `MyHumans/AppDelegate.swift` | Entry point |
| `MyHumans/Resources/harness.html` | The stub take-notes page, for developing without the web repo |
| *(moved)* | The bridge's TypeScript half lives in `lib/native/` in the `myhumansapp` repo, tests included — it moved at bolt-on (that repo's PR #254) and the `web/` folder here was deleted |

