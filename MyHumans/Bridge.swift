import CoreGraphics
import Foundation

/// The entire contract between the web app and this shell.
///
/// The web half lives in `lib/native/bridge.ts` in the `myhumansapp` repo, which is the source
/// of truth. Version 1 was four messages and a full-screen-only canvas; version 2 adds the
/// inline canvas — the same PencilKit surface embedded in the page at a rectangle the web side
/// reports, so a coach can write beside the person's details instead of leaving them.
///
/// Two rules keep the two repos from coupling. Both are load-bearing — the whole reason the
/// iPad app can be built in a separate repo while the web app ships independently:
///
///   1. The web app must work with no shell present. Every native path on that side sits
///      behind a `hasNativeInk()` check, and the tldraw canvas is always the fallback.
///   2. This shell must tolerate any web version. An unrecognised message is IGNORED, never
///      thrown. `version` and `caps` are how the web app feature-detects: a v1 web app never
///      sends a frame and gets the modal full-screen canvas; a v2 web app checks for
///      `'ink-inline'` before relying on it.
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

    static let version = 2
    static let caps = ["ink", "ink-inline"]

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
        /// With a `frame`, the canvas embeds in the page at that rectangle; without one it
        /// presents full screen, which is the whole v1 behaviour.
        case openInk(OpenInkRequest)

        /// The page laid out again — fullscreen toggled, the sidebar collapsed, the iPad
        /// rotated — and the inline canvas must move to the new rectangle.
        case setFrame(CGRect)

        /// Live preference change from the page's canvas-settings menu.
        case setPrefs(InkPrefs)

        /// The page's own undo/redo buttons. Routed to the canvas's undo manager, the same
        /// one the modal nav-bar buttons use.
        case undo
        case redo

        /// The page is done with the canvas — navigating away, or switching to the typed
        /// editor. The shell flushes (emits `ink.close`) and tears the canvas down.
        case finish

        /// A web dialog or overlay needs the screen: hide the canvas (it always draws above
        /// web content, so without this every dialog opens underneath it). Show restores it.
        case setHidden(Bool)

        /// The page deleted the note (its own Clear flow) and the canvas must blank WITHOUT
        /// emitting anything back — the web side already did the deleting.
        case clearCanvas

        /// Parses a raw script message. Returns nil for anything unrecognised or malformed —
        /// see rule 2. Never throws.
        init?(name: String, body: Any) {
            let dict = body as? [String: Any] ?? [:]
            switch name {
            case "ink.open":
                self = .openInk(OpenInkRequest(dict))
            case "ink.frame":
                guard let frame = Bridge.rect(from: dict["frame"]) else { return nil }
                self = .setFrame(frame)
            case "ink.prefs":
                self = .setPrefs(InkPrefs(dict))
            case "ink.undo":
                self = .undo
            case "ink.redo":
                self = .redo
            case "ink.finish":
                self = .finish
            case "ink.hidden":
                self = .setHidden((dict["hidden"] as? Bool) ?? false)
            case "ink.clearCanvas":
                self = .clearCanvas
            default:
                return nil
            }
        }
    }

    /// CSS pixels from `getBoundingClientRect`, which on this WKWebView are points 1:1 — the
    /// web view is pinned to the shell view's edges and the app's pages do not scroll or zoom.
    static func rect(from raw: Any?) -> CGRect? {
        guard
            let dict = raw as? [String: Any],
            let x = dict["x"] as? Double,
            let y = dict["y"] as? Double,
            let width = dict["width"] as? Double,
            let height = dict["height"] as? Double,
            width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
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

        /// Shown in the modal screen's navigation bar. The inline canvas has no bar — the page
        /// renders its own heading — so there it is unused.
        let title: String

        /// Whether to draw the page dark. Mirrors the web canvas's `#ffffff` / `#1e1e1e`.
        let darkMode: Bool

        /// Stable identity for the on-device recovery copy, independent of the note id.
        ///
        /// A brand-new note has no id until the web side's first commit mints one, and the shell
        /// is not told when that happens — so keying recovery by note id filed every new note
        /// under one shared "unsaved" slot, where the next blank page ANYONE opened would be
        /// offered it. The web side sends its own draft key, which is scoped to the person and
        /// the meeting, exists before the note does, and never collides across people.
        let recoveryKey: String?

        /// Where to embed, in the web view's coordinate space. Nil means full screen (v1).
        let frame: CGRect?

        /// Canvas preferences, applied at open. Nil fields keep defaults.
        let prefs: InkPrefs?

        init(_ dict: [String: Any]) {
            noteId = dict["noteId"] as? String
            drawing = dict["drawing"] as? String
            title = (dict["title"] as? String) ?? "Note"
            darkMode = (dict["darkMode"] as? Bool) ?? false
            recoveryKey = dict["recoveryKey"] as? String
            frame = Bridge.rect(from: dict["frame"])
            prefs = (dict["prefs"] as? [String: Any]).map(InkPrefs.init)
        }
    }

    /// Coach preferences for the canvas, chosen in the page's settings menu and persisted by
    /// the web side (they are per-device concerns, and the web side already has per-device
    /// storage). Every field optional so a partial update touches only what it names.
    struct InkPrefs {
        /// Two-finger scrolling only, so a resting finger cannot move the page. Nil = keep.
        let twoFingerScroll: Bool?
        /// Pin the zoom at fit-to-width, so a stray pinch cannot change the canvas size.
        let lockZoom: Bool?
        /// Overrides the page colour independently of the app theme. Nil = keep.
        let darkMode: Bool?

        init(_ dict: [String: Any]) {
            twoFingerScroll = dict["twoFingerScroll"] as? Bool
            lockZoom = dict["lockZoom"] as? Bool
            darkMode = dict["darkMode"] as? Bool
        }
    }
}

// MARK: - Native → web

extension Bridge {

    enum OutboundMessage: String {
        /// Debounced while writing. The web side treats this exactly as it treats a tldraw
        /// autosave tick: write the localStorage draft, then commit on its own schedule.
        case inkAutosave = "ink.autosave"

        /// The flush — the coach tapped Done on the modal screen, or the page sent
        /// `ink.finish`. The web side commits it as final.
        case inkClose = "ink.close"

        /// The incoming drawing could not be decoded. Saving is off, the canvas is gone, and
        /// the page should fall back to its read-only picture. A v1 web app's decoder returns
        /// null for the unknown name and ignores it — rule 2, working as designed.
        case inkLoadFailed = "ink.loadFailed"

        /// The coach cleared the page from the modal screen's own trash button. The web side
        /// deletes the saved record, matching what Clear does on the web canvas today.
        /// (The inline canvas never sends this: the page's Clear flow deletes first and tells
        /// the shell with `ink.clearCanvas`.)
        case inkDiscard = "ink.discard"
    }

    /// Payload for `ink.autosave` and `ink.close`.
    struct InkResult: Encodable {
        let noteId: String?

        /// Base64 `PKDrawing.dataRepresentation()` — the editable source. Opaque to everything
        /// downstream: the server gzips and stores it without knowing what produced it.
        /// Empty when `isEmpty` is true.
        let drawing: String

        /// Base64 PNG, background composited in. This is what every surface in the app actually
        /// renders, so it has to be a finished picture, not a transparent overlay.
        /// Empty when `isEmpty` is true.
        let png: String

        /// The coach left a blank page.
        ///
        /// `ink.close` fires even then, so the web page always learns the screen closed and can
        /// re-render — but it carries no content, and the web side's existing rule applies
        /// unchanged: erasing everything is not a request for a blank note, so nothing is
        /// committed. Deleting is what Clear is for.
        let isEmpty: Bool

        /// Which editor produced `drawing`. The web app stores this so it knows a tldraw canvas
        /// cannot open it.
        let format = "pencilkit"

        static func empty(noteId: String?) -> InkResult {
            InkResult(noteId: noteId, drawing: "", png: "", isEmpty: true)
        }
    }

    /// Payload for `ink.discard`.
    struct InkDiscard: Encodable {
        let noteId: String?
    }

    /// Payload for `ink.loadFailed`.
    struct InkLoadFailed: Encodable {
        let noteId: String?
    }
}
