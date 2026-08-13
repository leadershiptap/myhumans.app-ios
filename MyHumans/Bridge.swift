import Foundation

/// The entire contract between the web app and this shell: four messages.
///
/// The web half lives in `lib/native/bridge.ts` in the `myhumansapp` repo and is the source of
/// truth once the bolt-on lands. Until then this file is it, and `harness.html` is what
/// exercises it.
///
/// Two rules keep the two repos from coupling. Both are load-bearing — the whole reason the
/// iPad app can be built in a separate repo while the web app ships independently:
///
///   1. The web app must work with no shell present. Every native path on that side sits
///      behind a `hasNativeInk()` check, and the tldraw canvas is always the fallback.
///   2. This shell must tolerate any web version. An unrecognised message is IGNORED, never
///      thrown. `version` and `caps` are how the web app feature-detects.
///
/// Rule 2 has a second reason worth remembering: tldraw's own iOS guards key off `tlenv.isIos`,
/// a bare `/iPad|iPhone/` user-agent match that iPadOS Safari already fails. Whatever user
/// agent this shell presents changes which of tldraw's internal guards fire — which is why
/// `WebShellViewController` APPENDS to the user agent (via `applicationNameForUserAgent`)
/// rather than replacing it, and why nothing on either side is allowed to branch on the UA.
enum Bridge {

    /// Name of the `WKScriptMessageHandler`. Web side posts to
    /// `window.webkit.messageHandlers.myhumans.postMessage(...)`.
    static let messageHandlerName = "myhumans"

    static let version = 1
    static let caps = ["ink"]

    /// Injected at `.atDocumentStart`, before any page script runs, so a page can feature-detect
    /// synchronously during its first render rather than waiting for an event.
    static var injectedScript: String {
        let capsList = caps.map { "'\($0)'" }.joined(separator: ", ")
        return """
        window.__myhumansNative = { version: \(Bridge.version), caps: [\(capsList)] };
        """
    }

    /// Builds the JavaScript that delivers a message to the page.
    ///
    /// The payload is JSON, then base64'd, and the page does `JSON.parse(atob(...))`. That extra
    /// hop exists so nothing has to escape quotes, newlines or backslashes into a JS string
    /// literal — the PNG and drawing payloads are base64 blobs hundreds of kilobytes long, and a
    /// single escaping mistake there is a silent, intermittent data-loss bug.
    ///
    /// Returns nil if the payload cannot be encoded, which is a programming error rather than a
    /// runtime condition — the caller logs and drops it rather than sending malformed JS.
    static func emitScript<T: Encodable>(_ name: OutboundMessage, payload: T) -> String? {
        guard let json = try? JSONEncoder().encode(payload) else {
            assertionFailure("Bridge: could not encode payload for \(name.rawValue)")
            return nil
        }
        let b64 = json.base64EncodedString()
        return """
        (function () {
          var fn = window.__myhumansNativeEmit;
          if (typeof fn === 'function') { fn('\(name.rawValue)', '\(b64)'); }
        })();
        """
    }
}

// MARK: - Web → native

extension Bridge {

    enum InboundMessage {
        /// The web app is handing us a note to write on. `drawing` is nil for a new note.
        case openInk(OpenInkRequest)

        /// Parses a raw script message. Returns nil for anything unrecognised or malformed —
        /// see rule 2. Never throws.
        init?(name: String, body: Any) {
            guard name == "ink.open" else { return nil }
            guard let dict = body as? [String: Any] else { return nil }
            self = .openInk(OpenInkRequest(dict))
        }
    }

    struct OpenInkRequest {
        /// The Note record id, when the web app already has one. Nil for a note that has never
        /// been saved. Echoed back unchanged on every outbound message so the web side can match
        /// the reply to the note without holding state of its own.
        let noteId: String?

        /// Base64 `PKDrawing.dataRepresentation()`, exactly as it was stored. Deliberately kept
        /// as the raw string rather than decoded here: whether it loads is the ink screen's
        /// business, because a drawing that fails to load must DISABLE saving rather than
        /// present an empty page. An empty page that saves would overwrite real handwriting with
        /// nothing — the same failure `didFailToLoad()` guards against on the web side.
        let drawing: String?

        /// Shown in the ink screen's navigation bar. Purely cosmetic.
        let title: String

        /// Whether to draw the page dark. Mirrors the web canvas's `#ffffff` / `#1e1e1e`.
        let darkMode: Bool

        init(_ dict: [String: Any]) {
            noteId = dict["noteId"] as? String
            drawing = dict["drawing"] as? String
            title = (dict["title"] as? String) ?? "Note"
            darkMode = (dict["darkMode"] as? Bool) ?? false
        }
    }
}

// MARK: - Native → web

extension Bridge {

    enum OutboundMessage: String {
        /// Debounced while writing. The web side treats this exactly as it treats a tldraw
        /// autosave tick: write the localStorage draft, then commit on its own schedule.
        case inkAutosave = "ink.autosave"

        /// The coach tapped Done. This is the flush — the web side should commit it as final.
        case inkClose = "ink.close"

        /// The coach cleared the page. The web side deletes the saved record, matching what
        /// Clear does on the web canvas today.
        case inkDiscard = "ink.discard"
    }

    /// Payload for `ink.autosave` and `ink.close`.
    struct InkResult: Encodable {
        let noteId: String?
        /// Base64 `PKDrawing.dataRepresentation()` — the editable source. Opaque to everything
        /// downstream: the server gzips and stores it without knowing what produced it.
        let drawing: String
        /// Base64 PNG, background composited in. This is what every surface in the app actually
        /// renders, so it has to be a finished picture, not a transparent overlay.
        let png: String
        /// Which editor produced `drawing`. The web app stores this so it knows a tldraw canvas
        /// cannot open it.
        let format = "pencilkit"
    }

    /// Payload for `ink.discard`.
    struct InkDiscard: Encodable {
        let noteId: String?
    }
}
