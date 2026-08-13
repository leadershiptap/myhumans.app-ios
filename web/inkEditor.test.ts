import { describe, expect, it } from 'vitest'

import { chooseInkEditor, editorForNewNote, normalizeInkFormat, readonlyReason } from './inkEditor'

describe('normalizeInkFormat', () => {
  it('treats rows that predate the column as tldraw', () => {
    // The migration defaults to 'tldraw' for exactly this reason.
    expect(normalizeInkFormat(null)).toBe('tldraw')
    expect(normalizeInkFormat(undefined)).toBe('tldraw')
    expect(normalizeInkFormat('')).toBe('tldraw')
  })

  it('passes the two real formats through', () => {
    expect(normalizeInkFormat('tldraw')).toBe('tldraw')
    expect(normalizeInkFormat('pencilkit')).toBe('pencilkit')
  })

  it('does not coerce an unknown format into a real one', () => {
    // Coercing would hand a blob to an editor that cannot read it, which renders as an empty
    // page — and an empty page that saves overwrites real handwriting with nothing.
    expect(normalizeInkFormat('something-later')).toBe('unknown')
    expect(normalizeInkFormat(7)).toBe('unknown')
    expect(normalizeInkFormat({})).toBe('unknown')
  })
})

describe('chooseInkEditor', () => {
  it('opens a PencilKit note natively in the shell', () => {
    expect(chooseInkEditor('pencilkit', true)).toBe('native')
  })

  it('shows a PencilKit note read-only everywhere else', () => {
    // No PencilKit on desktop or Android, and no way to make one. The picture is already what
    // every other surface renders, so this loses editing and nothing else.
    expect(chooseInkEditor('pencilkit', false)).toBe('readonly')
  })

  it('falls back to the tldraw canvas for a tldraw note inside the shell', () => {
    // Glitchy in a web view, but it works — and the alternative silently loses those notes.
    expect(chooseInkEditor('tldraw', true)).toBe('tldraw')
  })

  it('uses tldraw for a tldraw note on the web, which is every note today', () => {
    expect(chooseInkEditor('tldraw', false)).toBe('tldraw')
  })

  it('treats a row written before the column existed as tldraw, on both sides', () => {
    // NOT the same question as "what should a new note use" — see editorForNewNote. Answering
    // both with one absent value is how a tldraw note gets handed to PencilKit.
    expect(chooseInkEditor(null, true)).toBe('tldraw')
    expect(chooseInkEditor(null, false)).toBe('tldraw')
  })

  it('refuses to open a format it does not recognise, on either side', () => {
    expect(chooseInkEditor('something-later', true)).toBe('readonly')
    expect(chooseInkEditor('something-later', false)).toBe('readonly')
  })

  it('never returns an editor that would open a blob it cannot read', () => {
    // The property that matters, stated directly: pencilkit never reaches tldraw, and tldraw
    // never reaches the native canvas.
    for (const shell of [true, false]) {
      expect(chooseInkEditor('pencilkit', shell)).not.toBe('tldraw')
      expect(chooseInkEditor('tldraw', shell)).not.toBe('native')
    }
  })
})

describe('editorForNewNote', () => {
  it('gives a blank page the best canvas the device has', () => {
    expect(editorForNewNote(true)).toBe('native')
    expect(editorForNewNote(false)).toBe('tldraw')
  })

  it('never opens a new note read-only', () => {
    // There is nothing to be read-only about, and a coach who cannot write is stuck.
    expect(editorForNewNote(true)).not.toBe('readonly')
    expect(editorForNewNote(false)).not.toBe('readonly')
  })
})

describe('readonlyReason', () => {
  it('tells an iPad owner where their note lives', () => {
    expect(readonlyReason('pencilkit')).toMatch(/iPad/)
  })

  it('says something true about a format it does not know', () => {
    expect(readonlyReason('something-later')).toMatch(/newer version/)
  })
})
