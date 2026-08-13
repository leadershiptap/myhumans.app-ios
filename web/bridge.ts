/**
 * The web half of the shell bridge. Mirrors `MyHumans/Bridge.swift`.
 *
 * This file lives here during the build-out and MOVES to `lib/native/bridge.ts` in the
 * `myhumansapp` repo at bolt-on, at which point it becomes the contract's source of truth and
 * this copy is deleted. It is written here so the two halves can be designed together and the
 * bolt-on is a move rather than a rewrite.
 *
 * Rule 1 governs everything below: **the web app must work with no shell present.** Every export
 * either returns a "no shell" answer or is a no-op when `window.__myhumansNative` is absent, so
 * a caller never has to guard before calling. On desktop and Android this module is inert.
 *
 * Rule 2 is the shell's side: it ignores messages it does not recognise. The mirror of that here
 * is `decodeEmit`, which returns null rather than throwing for anything unexpected — a newer
 * shell must never be able to crash an older page.
 */

// MARK: - Shape of the injected object

export interface NativeShell {
  version: number
  caps: string[]
}

/**
 * Pure. Exported for the test suite — the real reader is `nativeShell()`.
 *
 * Deliberately tolerant: an object with the right shape is accepted whatever else it carries,
 * because a future shell will add fields and an older page must keep working.
 */
export function parseShell(raw: unknown): NativeShell | null {
  if (typeof raw !== 'object' || raw === null) return null
  const candidate = raw as Record<string, unknown>
  const { version, caps } = candidate
  if (typeof version !== 'number' || !Number.isFinite(version)) return null
  if (!Array.isArray(caps)) return null
  if (!caps.every((c) => typeof c === 'string')) return null
  return { version, caps }
}

declare global {
  interface Window {
    __myhumansNative?: unknown
    __myhumansNativeEmit?: (name: string, b64: string) => void
    webkit?: {
      messageHandlers?: {
        myhumans?: { postMessage: (body: unknown) => void }
      }
    }
  }
}

/** Null everywhere except inside the iPad shell. */
export function nativeShell(): NativeShell | null {
  if (typeof window === 'undefined') return null
  return parseShell(window.__myhumansNative)
}

/**
 * The one check every call site uses.
 *
 * Ask this, never the user agent. tldraw's own iOS guards key off `tlenv.isIos`, a bare
 * `/iPad|iPhone/` match that iPadOS Safari already fails — the shell appends to the UA rather
 * than replacing it precisely so nothing has to reason about it.
 */
export function hasNativeInk(): boolean {
  return nativeShell()?.caps.includes('ink') ?? false
}

// MARK: - Web → native

export interface OpenInkRequest {
  /** The Note record id, when one exists. Null for a note that has never been saved. */
  noteId: string | null
  /** Base64 PencilKit drawing, exactly as stored. Null for a new note. */
  drawing: string | null
  /** Shown in the ink screen's navigation bar. */
  title: string
  darkMode: boolean
}

/**
 * Hands a note to the native canvas. Returns false when there is no shell, so a caller can fall
 * back to mounting `TldrawNoteCanvas` in the same expression.
 */
export function openNativeInk(request: OpenInkRequest): boolean {
  const handler = typeof window === 'undefined'
    ? undefined
    : window.webkit?.messageHandlers?.myhumans
  if (!handler || !hasNativeInk()) return false
  handler.postMessage({ name: 'ink.open', payload: request })
  return true
}

// MARK: - Native → web

export type NativeInkEvent =
  | {
      type: 'autosave' | 'close'
      noteId: string | null
      /** Base64 PencilKit drawing. Empty string when `isEmpty`. */
      drawing: string
      /** Base64 PNG, background already composited in. Empty string when `isEmpty`. */
      png: string
      /**
       * The coach left a blank page.
       *
       * `close` fires even then, so this page always learns the screen was dismissed and can
       * re-render. It carries no content, and the existing rule applies unchanged: erasing
       * everything is not a request for a blank note, so nothing is committed. Deleting is what
       * Clear is for, and that arrives as `discard`.
       */
      isEmpty: boolean
      format: 'pencilkit'
    }
  | { type: 'discard'; noteId: string | null }

/**
 * Pure. Decodes one message from the shell.
 *
 * The payload is JSON, then base64 — that hop exists so no blob has to survive escaping into a
 * JavaScript string literal, and `png` is routinely hundreds of kilobytes.
 *
 * Returns null for anything unrecognised or malformed. Never throws: an older page meeting a
 * newer shell must degrade, and a decode failure must not take the take-notes screen down while
 * a coach is mid-session.
 */
export function decodeEmit(name: string, b64: string): NativeInkEvent | null {
  let payload: Record<string, unknown>
  try {
    const parsed: unknown = JSON.parse(atob(b64))
    if (typeof parsed !== 'object' || parsed === null) return null
    payload = parsed as Record<string, unknown>
  } catch {
    return null
  }

  const noteId = typeof payload.noteId === 'string' ? payload.noteId : null

  if (name === 'ink.discard') return { type: 'discard', noteId }

  if (name !== 'ink.autosave' && name !== 'ink.close') return null

  const isEmpty = payload.isEmpty === true
  const drawing = typeof payload.drawing === 'string' ? payload.drawing : ''
  const png = typeof payload.png === 'string' ? payload.png : ''

  // Content that arrived incomplete is worse than none: a half-decoded save would overwrite
  // real handwriting with a fragment. Treat it as unrecognised.
  if (!isEmpty && (drawing === '' || png === '')) return null

  return {
    type: name === 'ink.autosave' ? 'autosave' : 'close',
    noteId,
    drawing,
    png,
    isEmpty,
    format: 'pencilkit',
  }
}

/**
 * Registers the receiver the shell calls into. Returns an unsubscribe function.
 *
 * Only one receiver can exist at a time — the shell calls a single global — so this restores
 * whatever was there before rather than deleting, which keeps a remount from silently
 * disconnecting a still-mounted canvas.
 */
export function onNativeInk(handler: (event: NativeInkEvent) => void): () => void {
  if (typeof window === 'undefined') return () => {}

  const previous = window.__myhumansNativeEmit
  window.__myhumansNativeEmit = (name: string, b64: string) => {
    const event = decodeEmit(name, b64)
    if (event) handler(event)
  }

  return () => {
    window.__myhumansNativeEmit = previous
  }
}
