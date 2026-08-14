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

- `.liveApp` — the real `myhumans.app`. **This is the default**, and has been since the bolt-on
  landed on 13 Aug 2026: the web app now opens the native canvas itself, so the shell has a
  real job to do from launch.
- `.harness` — the bundled `Resources/harness.html`. A stub take-notes page that drives the
  bridge against something we control. Still the fastest way to work on the ink screen without
  a round trip through Render, and still the only way to exercise the v1 full-screen flow.

There is deliberately no in-app switch — a debug toggle is one more thing that can be left in
the wrong position and ship, and this is a two-character edit and a rebuild.

> There is no localhost option and there cannot usefully be one: Clerk's production keys only
> resolve `myhumans.app`, so no authenticated page renders anywhere else. That constraint
> already governs the web repo.

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
| `ink.autosave` | `{ session, noteId, drawing, png, format }` | first save of a session ~6s after the pen lifts, then every 3 minutes |
| `ink.close` | `{ session, noteId, drawing, png, format }` | the flush — `ink.finish`, or Done on the modal screen |
| `ink.discard` | `{ session, noteId }` | the coach cleared the page from the modal screen |
| `ink.loadFailed` | `{ session, noteId }` | the stored drawing would not decode; saving is off and the canvas is gone |
| `ink.toolChanged` | `{ session, kind }` | the Pencil's own squeeze or double-tap switched tools |

`png` is EMPTY on the periodic saves. Rendering one is a full-page raster on the main thread and
the coach feels every one, so only the save that MINTS a record carries a picture, and so does
every flush. The web side keeps the note's existing picture in between.

`session` is the page's own draft key, and it is load-bearing rather than diagnostic: a flush
crosses the bridge asynchronously, and by the time it lands the page may have navigated to a
DIFFERENT person's take-notes screen. Without a tag saying whose handwriting it is, that page
accepts it and commits one coach's note into another person's record. It did, once.

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

## The bolt-on landed

It shipped on 13 Aug 2026 (`myhumansapp` PRs #254 and #258) and the web half now lives at
`lib/native/` in that repo, which is its source of truth. The `web/` folder that used to mirror
it here is gone, along with the CI job that tested it.

What the web side does, for orientation:

- `chooseInkEditor` / `editorForNewNote` decide which editor opens a note, from the
  `ink_format` column added in migration `0021`.
- `planNativeInk` decides what each message MEANS — write the draft then commit, delete,
  re-render, or ignore.
- `nativeInkSource` lets the existing `commit()` read from a shell message instead of a tldraw
  canvas, so the whole save path is shared rather than forked.
- The take-notes page renders the tool row, measures the rectangle the canvas embeds into, and
  owns the size tables.

**Handwriting is iPad-only now.** The Draw tab in a browser says so and points at Type. Ink
notes still render everywhere, read-only, from the same flattened PNG they always did.

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
| `MyHumans/WebShellViewController.swift` | The `WKWebView`, the message handler, inline canvas hosting, popup + alert handling |
| `MyHumans/InkCanvasViewController.swift` | `PKCanvasView` + tools, autosave, PNG export, Pencil gestures |
| `MyHumans/InkRecovery.swift` | The on-device crash copy of a drawing in progress |
| `MyHumans/Config.swift` | What to load, timings, export limits, page width |
| `MyHumans/Resources/harness.html` | The stub take-notes page, for developing without the web repo |

The bridge's TypeScript half lives in `lib/native/` in the `myhumansapp` repo — it moved there
at bolt-on, tests included, and a copy here would only drift.
