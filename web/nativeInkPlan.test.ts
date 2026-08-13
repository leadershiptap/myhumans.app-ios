import { describe, expect, it } from 'vitest'

import type { NativeInkEvent } from './bridge'
import { planNativeInk } from './nativeInkPlan'

const b64 = (s: string) => Buffer.from(s).toString('base64')

const message = (
  type: 'autosave' | 'close',
  over: Partial<Extract<NativeInkEvent, { type: 'autosave' | 'close' }>> = {},
): NativeInkEvent => ({
  type,
  noteId: 'recABC',
  drawing: b64('drawing-bytes'),
  png: b64('png-bytes'),
  isEmpty: false,
  format: 'pencilkit',
  ...over,
})

describe('planNativeInk', () => {
  it('saves an autosave without forcing a new picture', () => {
    // The picture is refreshed on a slower cadence than the handwriting. Forcing it here would
    // put a full page rebuild on every pause in writing.
    expect(planNativeInk(message('autosave'))).toEqual({
      action: 'save',
      snapshot: b64('drawing-bytes'),
      png: b64('png-bytes'),
      forceImage: false,
      noteId: 'recABC',
    })
  })

  it('forces the picture on the way out', () => {
    // Done is the flush. Whatever the coach last wrote has to reach the previews, which read the
    // picture and nothing else.
    const plan = planNativeInk(message('close'))
    expect(plan).toMatchObject({ action: 'save', forceImage: true })
  })

  it('carries a null note id straight through for a note never saved', () => {
    expect(planNativeInk(message('close', { noteId: null }))).toMatchObject({
      action: 'save',
      noteId: null,
    })
  })

  it('deletes on discard', () => {
    expect(planNativeInk({ type: 'discard', noteId: 'recABC' })).toEqual({
      action: 'delete',
      noteId: 'recABC',
    })
  })

  it('treats a blank close as the screen closing, not as a note', () => {
    // Erasing everything is not a request for a blank note. The page still has to learn the
    // screen was dismissed, so this is neither a save nor nothing.
    expect(planNativeInk(message('close', { isEmpty: true, drawing: '', png: '' }))).toEqual({
      action: 'closed',
    })
  })

  it('never writes a blank autosave over real handwriting', () => {
    // The shell does not send this. If a future one ever does, writing an empty page over a
    // saved note is the worst thing this path could do, so it is ignored rather than trusted.
    expect(planNativeInk(message('autosave', { isEmpty: true, drawing: '', png: '' }))).toEqual({
      action: 'ignore',
    })
  })

  it('ignores a message missing either blob', () => {
    // Unreachable through decodeEmit, which already refuses these. Asserted anyway: a
    // half-decoded save would overwrite handwriting with a fragment.
    expect(planNativeInk(message('close', { drawing: '' }))).toEqual({ action: 'ignore' })
    expect(planNativeInk(message('close', { png: '' }))).toEqual({ action: 'ignore' })
  })

  it('is total — every event the bridge can decode produces a plan', () => {
    const events: NativeInkEvent[] = [
      message('autosave'),
      message('close'),
      message('autosave', { isEmpty: true, drawing: '', png: '' }),
      message('close', { isEmpty: true, drawing: '', png: '' }),
      { type: 'discard', noteId: null },
    ]
    for (const event of events) {
      expect(planNativeInk(event).action).toMatch(/^(save|delete|closed|ignore)$/)
    }
  })
})
