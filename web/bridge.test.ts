import { describe, expect, it } from 'vitest'

import { decodeEmit, parseShell } from './bridge'

/**
 * Moves to `lib/native/bridge.test.ts` alongside the module at bolt-on.
 *
 * The pure half is the only part of this feature that can be verified without an iPad — the same
 * position `lib/ink/toolDock.ts` is in. Everything else needs the deployed site and a Pencil,
 * because Clerk's production keys only resolve `myhumans.app`.
 */

const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64')

describe('parseShell', () => {
  it('reads the injected object', () => {
    expect(parseShell({ version: 1, caps: ['ink'] })).toEqual({ version: 1, caps: ['ink'] })
  })

  it('tolerates fields a newer shell adds', () => {
    const parsed = parseShell({ version: 2, caps: ['ink', 'camera'], platform: 'ipad' })
    expect(parsed).toEqual({ version: 2, caps: ['ink', 'camera'] })
  })

  it('is null when there is no shell', () => {
    expect(parseShell(undefined)).toBeNull()
    expect(parseShell(null)).toBeNull()
  })

  it('rejects a malformed object rather than half-trusting it', () => {
    expect(parseShell({ caps: ['ink'] })).toBeNull()
    expect(parseShell({ version: '1', caps: ['ink'] })).toBeNull()
    expect(parseShell({ version: 1, caps: 'ink' })).toBeNull()
    expect(parseShell({ version: 1, caps: [1, 2] })).toBeNull()
  })
})

describe('decodeEmit', () => {
  const result = {
    noteId: 'recABC',
    drawing: 'ZHJhd2luZw==',
    png: 'cG5n',
    isEmpty: false,
    format: 'pencilkit',
  }

  it('decodes an autosave', () => {
    expect(decodeEmit('ink.autosave', encode(result))).toEqual({
      type: 'autosave',
      noteId: 'recABC',
      drawing: 'ZHJhd2luZw==',
      png: 'cG5n',
      isEmpty: false,
      format: 'pencilkit',
    })
  })

  it('decodes a close', () => {
    expect(decodeEmit('ink.close', encode(result))?.type).toBe('close')
  })

  it('decodes a discard', () => {
    expect(decodeEmit('ink.discard', encode({ noteId: 'recABC' }))).toEqual({
      type: 'discard',
      noteId: 'recABC',
    })
  })

  it('carries an empty close through, so the page learns the screen was dismissed', () => {
    const empty = { noteId: 'recABC', drawing: '', png: '', isEmpty: true, format: 'pencilkit' }
    expect(decodeEmit('ink.close', encode(empty))).toEqual({
      type: 'close',
      noteId: 'recABC',
      drawing: '',
      png: '',
      isEmpty: true,
      format: 'pencilkit',
    })
  })

  it('accepts a note that has never been saved', () => {
    expect(decodeEmit('ink.autosave', encode({ ...result, noteId: null }))?.noteId).toBeNull()
  })

  it('ignores a message name it does not know, so a newer shell cannot break the page', () => {
    expect(decodeEmit('ink.somethingNew', encode(result))).toBeNull()
  })

  it('returns null rather than throwing on malformed input', () => {
    expect(decodeEmit('ink.autosave', 'not base64 !!')).toBeNull()
    expect(decodeEmit('ink.autosave', Buffer.from('{oops').toString('base64'))).toBeNull()
    expect(decodeEmit('ink.autosave', encode('a string'))).toBeNull()
    expect(decodeEmit('ink.autosave', encode(null))).toBeNull()
  })

  it('refuses a non-empty result missing either half', () => {
    // A fragment that got saved would overwrite real handwriting with part of a note, which is
    // worse than dropping the tick — the next one carries the full state.
    expect(decodeEmit('ink.close', encode({ ...result, png: '' }))).toBeNull()
    expect(decodeEmit('ink.close', encode({ ...result, drawing: '' }))).toBeNull()
  })
})
