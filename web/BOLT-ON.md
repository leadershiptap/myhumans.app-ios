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
| `web/nativeInkPlan.ts` | `lib/native/nativeInkPlan.ts` |
| `web/nativeInkPlan.test.ts` | `lib/native/nativeInkPlan.test.ts` |
| `web/inkEditor.ts` | `lib/native/inkEditor.ts` |
| `web/inkEditor.test.ts` | `lib/native/inkEditor.test.ts` |

43 tests, all passing here, and the four sources type-check under `--strict`. Delete `web/` from
this repo once they have moved.

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
- Register `onNativeInk` in an effect and hand each event to `planNativeInk`, then do what it says:

| Plan | What to do |
|---|---|
| `save` | `writeDraft(...)` **first**, then `commit({ forceImage, final })` with the flags from the plan |
| `delete` | the existing discard path — bump `discardGenRef`, `clearDraft`, `deleteNoteAction` |
| `closed` | re-render so the page stops showing an editing state. Write nothing |
| `ignore` | nothing, and nothing to undo |

> **A correction that was itself wrong — read this before trusting a claim about the other repo.**
> This document briefly said `commit()` has no `final` option and takes `{ forceImage }` alone.
> That was wrong, and the original text was right: the signature is
> `commit({ forceImage = false, final = false })`.
>
> The mistake came from reading `TakeNotesCanvas.tsx` in the local `myhumansapp` checkout without
> checking what it was pointed at. It sits on an abandoned branch **120 commits behind `main`** —
> `claude/docs-after-outbox`, whose remote was deleted — and on that commit the signature
> genuinely did take `forceImage` alone. Everything about the reading was careful except the one
> step that mattered.
>
> The number in this paragraph was itself wrong once. It said "nine commits", a figure never
> measured — the two `git log` outputs merely looked a few apart. `git rev-list --count` says 120.
> Guessing a specific number reads exactly like having counted one, which is what makes it worse
> than saying "behind".
>
> **So: `git log --oneline -1` and `git status -sb` in that repo before quoting a line number out
> of it.** A stale checkout reads exactly like a current one, and both halves of this contract are
> designed on the assumption that what is written here matches what is actually there.
>
> `forceImage` and `final` are deliberately separate. `forceImage` refreshes the PNG every note
> preview reads. `final` revalidates the person's profile, which Next turns into a full page
> rebuild — around 30 database reads, and paying that every few seconds of handwriting is what
> stalled the app mid-session.

The whole routing decision is `planNativeInk` in `nativeInkPlan.ts` — a pure function with 8
tests, so the rules that cost something when got wrong (an empty page overwriting handwriting, a
discard that leaves the record behind) are verifiable without a React tree, an iPad or a network.
The handler below is the executor and stays deliberately dumb:

```ts
useEffect(() => onNativeInk((event) => {
  const plan = planNativeInk(event)
  switch (plan.action) {
    case 'save':
      // Draft first. `commit()` returns early when offline, and until this message arrived the
      // drawing lived in the native canvas and nowhere else.
      writeDraft(draftKey, metaKey, plan.snapshot, captionRef.current, noteIdRef.current)
      lastEventRef.current = event            // what `inkSourceRef` reads
      void commitRef.current({ forceImage: plan.forceImage })
      break
    case 'delete':
      void handleClearRef.current()
      break
    case 'closed':
      setNativeEditing(false)
      break
    case 'ignore':
      break
  }
}), [draftKey, metaKey])
```

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

Both live in `chooseInkEditor` in `inkEditor.ts`, with `normalizeInkFormat` for the data layer.
Three things it does that are worth not undoing:

- **An unrecognised format opens read-only on both sides**, rather than being coerced to a real
  one. A blob handed to an editor that cannot read it renders as an empty page, and an empty page
  that saves overwrites real handwriting with nothing.
- **A new note goes through `editorForNewNote`, not `chooseInkEditor`.** A missing format means
  "row written before the column existed", which is tldraw. "Nothing written yet" is a different
  question with a different answer, and answering both with one absent value hands a tldraw note
  to PencilKit. This was a real bug in the first draft, caught by its own test.
- **The reason string is separate** (`readonlyReason`), because what to tell a coach who cannot
  edit differs between "your note is on your iPad" and "this app is out of date".

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
