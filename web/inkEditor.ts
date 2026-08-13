/**
 * Which editor opens a given note.
 *
 * Moves to `lib/native/inkEditor.ts` in the `myhumansapp` repo at bolt-on.
 *
 * Two formats now exist for the same field. `updateInkNoteFields` and `compressSnapshot` take an
 * opaque string and gzip it, so a base64 `PKDrawing` drops into the existing column with no
 * migration of its own — but a tldraw canvas handed a PencilKit blob will fail to load, and the
 * reverse is equally true. The `ink_format` discriminator is what stops that, and this is the one
 * place that reads it.
 *
 * Every answer degrades rather than breaks. Nothing here can destroy handwriting: the worst case
 * is a note that shows as a picture with no way to edit it on that device, which is recoverable
 * by opening it somewhere else.
 */

/** The values the `ink_format` column is allowed to hold today. */
export type InkFormat = 'tldraw' | 'pencilkit'

export type InkEditor =
  /** The PencilKit screen in the iPad shell. */
  | 'native'
  /** The tldraw canvas. In the shell this is the web canvas inside the web view — glitchy, but it works. */
  | 'tldraw'
  /** Show the flattened picture and say where it can be edited. Never opens a canvas. */
  | 'readonly'

/**
 * Existing rows predate the column and are tldraw, which is why the migration defaults to it:
 *
 *     ALTER TABLE notes ADD COLUMN ink_format text NOT NULL DEFAULT 'tldraw';
 *
 * An unrecognised value is NOT coerced to a real format. A future format opened by an editor that
 * does not understand it renders as an empty page, and an empty page that saves overwrites real
 * handwriting with nothing — the failure this whole feature keeps guarding against.
 */
export function normalizeInkFormat(raw: unknown): InkFormat | 'unknown' {
  if (raw === null || raw === undefined || raw === '') return 'tldraw'
  if (raw === 'tldraw' || raw === 'pencilkit') return raw
  return 'unknown'
}

/**
 * Which editor opens a note that already exists. `shellPresent` is `hasNativeInk()`, never the
 * user agent.
 *
 * A missing format here means a row written before the column existed — that is tldraw, and it is
 * NOT the same question as "what should a brand-new note use". Answering both with one absent
 * value is how a tldraw note ends up handed to PencilKit, so new notes go through
 * `editorForNewNote` instead and this function never has to guess which case it is in.
 */
export function chooseInkEditor(rawFormat: unknown, shellPresent: boolean): InkEditor {
  const format = normalizeInkFormat(rawFormat)

  // Neither editor can be trusted with a format that postdates them. Show the picture.
  if (format === 'unknown') return 'readonly'

  if (format === 'pencilkit') {
    // On desktop and Android there is no PencilKit, and no way to make one. The picture is
    // already what every other surface in the app renders, so this loses nothing but editing.
    return shellPresent ? 'native' : 'readonly'
  }

  // A tldraw note inside the shell falls back to the tldraw canvas in the web view rather than
  // being opened by PencilKit, which cannot read it. Of the 298 notes carrying ink data, 294 came
  // from the OneNote import and only 4 are tldraw-authored, so this path is nearly theoretical —
  // but "nearly" is doing no work here, because the alternative silently loses those 4.
  return 'tldraw'
}

/**
 * Which editor a blank page should open in. There is no stored format to read — nothing has been
 * written yet — so the only question is what this device can do, and the shell exists precisely
 * to be the better answer on an iPad.
 */
export function editorForNewNote(shellPresent: boolean): InkEditor {
  return shellPresent ? 'native' : 'tldraw'
}

/** What to tell a coach who cannot edit the note where they are standing. */
export function readonlyReason(rawFormat: unknown): string {
  return normalizeInkFormat(rawFormat) === 'pencilkit'
    ? 'Written on an iPad with an Apple Pencil. Open it on your iPad to edit.'
    : 'This note was written in a newer version of the app. Open it there to edit.'
}
