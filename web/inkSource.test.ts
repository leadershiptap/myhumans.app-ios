import { describe, expect, it } from 'vitest'

import type { NativeInkEvent } from './bridge'
import { base64ToPngBlob, nativeInkSource } from './inkSource'

const b64 = (s: string) => Buffer.from(s).toString('base64')

const content = (over: Partial<Extract<NativeInkEvent, { type: 'close' }>> = {}) => ({
  type: 'close' as const,
  noteId: 'recABC',
  drawing: b64('drawing-bytes'),
  png: b64('png-bytes'),
  isEmpty: false,
  format: 'pencilkit' as const,
  ...over,
})

describe('nativeInkSource', () => {
  it('reads the snapshot straight through', () => {
    expect(nativeInkSource(content()).getSnapshot()).toBe(b64('drawing-bytes'))
  })

  it('is empty before anything has arrived', () => {
    const source = nativeInkSource(null)
    expect(source.isEmpty()).toBe(true)
    expect(source.getSnapshot()).toBeNull()
  })

  it('is empty when the coach closed a blank page', () => {
    // ink.close fires for a blank page so the screen learns it was dismissed. It must read as
    // empty here, so commit() bails exactly the way it does for an erased tldraw canvas.
    const source = nativeInkSource(content({ isEmpty: true, drawing: '', png: '' }))
    expect(source.isEmpty()).toBe(true)
  })

  it('is empty after a discard', () => {
    const source = nativeInkSource({ type: 'discard', noteId: 'recABC' })
    expect(source.isEmpty()).toBe(true)
    expect(source.getSnapshot()).toBeNull()
  })

  it('never reports a failed load, because a failed load sends nothing at all', () => {
    expect(nativeInkSource(null).didFailToLoad()).toBe(false)
    expect(nativeInkSource(content()).didFailToLoad()).toBe(false)
  })

  it('hands back a PNG blob commit() can upload', async () => {
    const blob = await nativeInkSource(content()).exportBlob()
    expect(blob).toBeInstanceOf(Blob)
    expect(blob?.type).toBe('image/png')
    expect(await blob?.text()).toBe('png-bytes')
  })

  it('has no blob to export when there is nothing written', async () => {
    expect(await nativeInkSource(null).exportBlob()).toBeNull()
  })
})

describe('base64ToPngBlob', () => {
  it('decodes to the original bytes', async () => {
    expect(await base64ToPngBlob(b64('hello'))?.text()).toBe('hello')
  })

  it('is null rather than throwing on malformed input', () => {
    // A failed decode must leave the note alone and let the next message carry the full state.
    expect(base64ToPngBlob('not base64 !!')).toBeNull()
    expect(base64ToPngBlob('')).toBeNull()
  })
})
