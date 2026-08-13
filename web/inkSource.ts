/**
 * The seam that lets the native canvas reuse the autosave engine instead of copying it.
 *
 * Moves to `lib/native/inkSource.ts` in the `myhumansapp` repo at bolt-on.
 *
 * `commit()` in `TakeNotesCanvas.tsx` is ~120 lines of hard-won behaviour: the single-flight
 * guard, the slower picture cadence, the refusal to mint a record with no picture, the
 * not-found re-create path, the `discardGenRef` generation guard that undoes a write the coach
 * discarded mid-flight, the draft that is deliberately NOT cleared on success, and the
 * `final` / `forceImage` split that keeps a page rebuild off every four seconds of handwriting.
 *
 * None of that is tldraw-specific. Reading the file, `commit()` touches the canvas for exactly
 * four things — `didFailToLoad()`, `isEmpty()`, `getSnapshot()` and `exportBlob()`. So the
 * bolt-on does not fork `commit()`; it narrows what `commit()` reads from to this interface and
 * hands it either the tldraw handle or a native source. The tldraw handle already satisfies it
 * structurally, so that half is a type annotation and nothing else.
 */

import type { NativeInkEvent } from './bridge'

/** The four things `commit()` actually needs. `TldrawNoteCanvasHandle` already provides them. */
export interface InkSource {
  /** True when the note's original handwriting failed to load — commit must refuse. */
  didFailToLoad: () => boolean
  /** True when there is nothing to save. Erasing everything is not a request for a blank note. */
  isEmpty: () => boolean
  /** The opaque editable source. The server gzips it without knowing what produced it. */
  getSnapshot: () => string | null
  /** The flattened picture every note preview in the app reads. */
  exportBlob: () => Promise<Blob | null>
}

/**
 * Wraps the most recent message from the iPad shell as something `commit()` can read.
 *
 * The native screen pushes rather than being polled, so the 250ms scheduler that drives the
 * tldraw canvas does not run on this path — each message calls `commit()` directly. Everything
 * downstream of that call is shared, unchanged.
 */
export function nativeInkSource(event: NativeInkEvent | null): InkSource {
  const content = event && event.type !== 'discard' && !event.isEmpty ? event : null

  return {
    // Always false, and that is not an oversight. The shell refuses to send anything at all
    // when the incoming drawing failed to decode — precisely so a blank page can never be
    // reported as the note's new state. Nothing arriving IS the guard; there is no separate
    // signal to relay.
    didFailToLoad: () => false,

    isEmpty: () => content === null,

    getSnapshot: () => content?.drawing ?? null,

    exportBlob: async () => (content ? base64ToPngBlob(content.png) : null),
  }
}

/**
 * The PNG crosses the bridge as base64 because it has to survive being embedded in a JavaScript
 * string. `commit()` wants a Blob to put in a FormData, so it is decoded once, here.
 *
 * Returns null rather than throwing on malformed input: a failed decode must leave the note
 * alone and let the next message carry the full state, not take down the take-notes screen
 * while a coach is mid-session.
 */
export function base64ToPngBlob(b64: string): Blob | null {
  if (!b64) return null
  try {
    const binary = atob(b64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
    return new Blob([bytes], { type: 'image/png' })
  } catch {
    return null
  }
}
