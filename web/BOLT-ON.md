# The bolt-on

What lands in the `myhumansapp` repo when this shell is ready. One PR, after the Postgres
cutover. Written against the real code, not from memory.

Until then **nothing in that repo changes.** Everything except the ink handoff is already
testable by pointing `Config.startTarget` at `.liveApp`.

## The seam

`commit()` in `app/(protected)/myhumans/[id]/take-notes/TakeNotesCanvas.tsx` is ~120 lines of
behaviour that took real incidents to arrive at — single-flight, the slower picture cadence, the
refusal to mint a record with no picture, the not-found re-create path, the `discardGenRef`
generation guard that undoes a write the coach discarded mid-flight, the draft deliberately not
cleared on success, and the `final` / `forceImage` split that keeps a full page rebuild off every
four seconds of handwriting.

**None of it is tldraw-specific.** Reading the function, it touches the canvas for exactly four
things:

```ts
h.didFailToLoad()   // line 461
h.isEmpty()         // line 468
h.getSnapshot()     // line 469
h.exportBlob()      // line 487
```

So the bolt-on does not fork `commit()`. It narrows what `commit()` reads from to the `InkSource`
interface in `inkSource.ts` and hands it either the tldraw handle or a native source.
`TldrawNoteCanvasHandle` already satisfies `InkSource` structurally, so that half is a type
annotation and no behaviour change at all.

## The change, file by file

### 1. New files — copied from this folder, unchanged

| From here | To |
|---|---|
| `web/bridge.ts` | `lib/native/bridge.ts` |
| `web/bridge.test.ts` | `lib/native/bridge.test.ts` |
| `web/inkSource.ts` | `lib/native/inkSource.ts` |
| `web/inkSource.test.ts` | `lib/native/inkSource.test.ts` |

21 tests, all passing here. Delete `web/` from this repo once they have moved.

### 2. `TakeNotesCanvas.tsx`

**One line in `commit()`:**

```diff
-    const h = canvasRef.current
+    const h = inkSourceRef.current
```

where `inkSourceRef` holds `canvasRef.current` on the web path and `nativeInkSource(lastEvent)`
on the iPad. Nothing else in the function moves.

**A native branch, roughly 60 lines:**

- When `hasNativeInk()`, do not mount `TldrawNoteCanvas`. Render the note's current picture (or
  an empty page) and a button that calls `openNativeInk({ noteId, drawing, title, darkMode })`.
- Register `onNativeInk` in an effect and route each event:

| Event | What to do |
|---|---|
| `autosave` | `writeDraft(...)` **first**, then `commit({ final: false })` |
| `close` | `writeDraft(...)`, then `commit({ forceImage: true, final: true })` |
| `discard` | the existing discard path — bump `discardGenRef`, `deleteNoteAction` |

- Do not run the 250ms scheduler on the native path. It polls `takeDirty()` / `isBusy()` /
  `msSincePenActivity()`, which only a live tldraw editor can answer; the native screen pushes
  instead. The scheduler, the tool dock and the whole dock-position machinery are web-only.

**Writing the draft on `autosave` is load-bearing, not tidiness.** `commit()` returns early when
offline (line 462). The drawing lives in the native canvas and nowhere else until this message
arrives, so if the draft is not written here, a force-quit while offline loses everything the
coach wrote. On the tldraw path the draft is written by the scheduler; on this path there is no
scheduler, so it has to happen in the handler.

### 3. `take-notes/page.tsx`

Add `inkFormat` to `ExistingInkNote`, which is deliberately narrow (three fields) because the
workspace is a client component and `inkImageUrl` must never cross the boundary. Keep it narrow.

### 4. The notes data layer, and one migration

```sql
ALTER TABLE notes ADD COLUMN ink_format text NOT NULL DEFAULT 'tldraw';
```

Read it and write it. Nothing else in the schema changes: `updateInkNoteFields` and
`compressSnapshot` already take an **opaque string**, gzip it and store it, so a base64
`PKDrawing` drops into the existing field with no migration of its own.

Then two rules, both of which degrade rather than break:

- A `pencilkit` note **on the web** renders its picture read-only — "Open on iPad to edit."
- A `tldraw` note **in the shell** falls back to the tldraw canvas in the web view. It still
  works; it is just glitchy. Of the 298 notes carrying ink data, 294 came from the OneNote
  import and only **4** are tldraw-authored, so this path is nearly theoretical.

### 5. Docs

`CLAUDE.md` and `docs/gotchas/ink-and-take-notes.md`: the shell exists, and the bridge's two
rules (the web app must work with no shell; the shell ignores what it does not recognise).

## No read path changes

Ink is already rendered everywhere from a flattened PNG served through
`/api/notes/[id]/ink-image` — `InkPage`, `NoteBody`, `NoteItem`, `PreviousNotesRail`,
`PreviousNotesDialog`. PencilKit produces that PNG exactly as tldraw does, with the page colour
composited in to match. Not one of those files is touched.

## Estimate

Larger than the "~10 lines" in the original plan, which was written before reading `commit()`.
Realistically **one to two days**: the four new files are done and tested, the `commit()` change
is one line, and the native branch plus the format discriminator is the actual work.
