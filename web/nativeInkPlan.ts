/**
 * What the take-notes page should DO about a message from the iPad shell.
 *
 * Moves to `lib/native/nativeInkPlan.ts` in the `myhumansapp` repo at bolt-on.
 *
 * This is deliberately a pure function rather than logic inlined into the event handler in
 * `TakeNotesCanvas.tsx`. The rules it encodes are the ones that cost something when they are got
 * wrong — an empty page overwriting real handwriting, a discard that leaves the record behind, a
 * draft not written before an offline commit gives up — and they are worth being able to test
 * without a React tree, a tldraw editor, an iPad, or a network.
 *
 * The component keeps the doing. This keeps the deciding.
 */

import type { NativeInkEvent } from './bridge'

/**
 * `save` — write the draft, THEN commit. The order is load-bearing, not tidiness: `commit()`
 * returns early when offline, and until this message arrives the drawing lives in the native
 * canvas and nowhere else. On the tldraw path the scheduler writes the draft; on this path there
 * is no scheduler, so if the handler does not write it, a force-quit while offline loses
 * everything the coach wrote.
 *
 * `forceImage` maps to `commit({ forceImage })`. Note there is no `final` flag — `commit()` takes
 * exactly one option, and an earlier draft of `BOLT-ON.md` said otherwise.
 *
 * `delete` — the existing discard path: bump `discardGenRef`, clear the draft, `deleteNoteAction`.
 *
 * `closed` — the screen was dismissed with nothing on it. Re-render so the page stops showing an
 * editing state, and write nothing. Erasing everything is not a request for a blank note; that is
 * what Clear, and therefore `delete`, is for.
 *
 * `ignore` — nothing to do, and nothing to undo.
 */
export type NativeInkPlan =
  | {
      action: 'save'
      /** The opaque editable drawing. Goes to the draft and to `commit()`'s snapshot. */
      snapshot: string
      /** Base64 PNG with the page colour already composited in. */
      png: string
      /** True only on the way out, so a page rebuild stays off every autosave. */
      forceImage: boolean
      noteId: string | null
    }
  | { action: 'delete'; noteId: string | null }
  | { action: 'closed' }
  | { action: 'ignore' }

export function planNativeInk(event: NativeInkEvent): NativeInkPlan {
  if (event.type === 'discard') {
    return { action: 'delete', noteId: event.noteId }
  }

  if (event.isEmpty) {
    // A close still has to be told to the page — the screen went away and the UI has to stop
    // pretending otherwise. An empty autosave should never arrive at all (the shell does not
    // send one), and if a future shell ever does, writing a blank page over real handwriting is
    // the single worst thing this path could do. So it is ignored rather than trusted.
    return event.type === 'close' ? { action: 'closed' } : { action: 'ignore' }
  }

  // Belt and braces. `decodeEmit` already refuses a non-empty message missing either blob, so
  // this should be unreachable — but a half-decoded save overwriting real handwriting with a
  // fragment is exactly the failure worth being unreachable twice.
  if (!event.drawing || !event.png) return { action: 'ignore' }

  return {
    action: 'save',
    snapshot: event.drawing,
    png: event.png,
    forceImage: event.type === 'close',
    noteId: event.noteId,
  }
}
