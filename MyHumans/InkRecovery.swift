import Foundation
import PencilKit

/// A last-resort copy of the handwriting on screen, kept on this device only.
///
/// Between the pen lifting and an autosave crossing the bridge, the drawing exists in the canvas
/// and nowhere else. If iOS kills the app in that window — low memory, a long spell in the
/// background, a genuine crash — the strokes go with it. With a test scribble that is nothing;
/// with a real note about a real person it is a real loss, and the coach has no way to know it
/// happened.
///
/// This is deliberately **not** a save path. Nothing here talks to the web app, the database or
/// Cloudinary, and a recovered drawing is *offered back* rather than committed: only the coach can
/// say whether what they wrote before the app died is still the note they want. All persistence
/// that counts still belongs to the web app.
enum InkRecovery {

    /// A note that has never been saved has no id yet, and still deserves recovering.
    private static let unsavedKey = "__unsaved__"

    private static var directory: URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else { return nil }

        let dir = base.appendingPathComponent("InkRecovery", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Note ids come from the web app and are opaque to this shell, so they are percent-encoded
    /// rather than trusted as filenames.
    private static func url(for noteId: String?) -> URL? {
        let raw = (noteId?.isEmpty == false ? noteId! : unsavedKey)
        let safe = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? unsavedKey
        return directory?.appendingPathComponent("\(safe).pkdrawing")
    }

    /// Writes the drawing, replacing any previous copy for this note.
    ///
    /// An empty drawing is never written. An empty page is not a note, and a stale empty file
    /// offering itself back after a crash would be worse than no file at all.
    static func save(_ drawing: PKDrawing, noteId: String?) {
        guard !drawing.bounds.isNull, !drawing.bounds.isEmpty else {
            clear(noteId: noteId)
            return
        }
        guard let url = url(for: noteId) else { return }
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    /// Returns a recoverable drawing, or nil if there is nothing to recover.
    ///
    /// A file that will not decode is deleted rather than reported: it cannot be shown to anyone,
    /// and leaving it behind means offering the same broken recovery on every future open.
    static func load(noteId: String?) -> PKDrawing? {
        guard
            let url = url(for: noteId),
            let data = try? Data(contentsOf: url)
        else { return nil }

        guard let drawing = try? PKDrawing(data: data) else {
            clear(noteId: noteId)
            return nil
        }
        guard !drawing.bounds.isNull, !drawing.bounds.isEmpty else {
            clear(noteId: noteId)
            return nil
        }
        return drawing
    }

    /// Called once the drawing has safely left this screen — the Done flush, or a deliberate
    /// Clear. Past that point the copy is stale, and stale recovery is its own kind of data loss.
    static func clear(noteId: String?) {
        guard let url = url(for: noteId) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
