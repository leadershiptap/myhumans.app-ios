import CoreGraphics
import Foundation
import UIKit

extension UIColor {
    /// `#rrggbb` from the web toolbar. Falls back to near-black rather than failing: a coach
    /// mid-sentence needs a pen more than they need a correct shade.
    convenience init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self.init(red: 0x0f / 255, green: 0x17 / 255, blue: 0x2a / 255, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }
}

enum Config {

    /// What the shell loads on launch.
    enum StartTarget {
        /// The real app. Everything except the ink handoff can be exercised this way from day
        /// one, with no change to the `myhumansapp` repo — sign-in, session persistence across a
        /// force-quit, every screen, the Microsoft calendar-connect redirect.
        case liveApp

        /// The bundled stub page, `Resources/harness.html`. Drives all four bridge messages
        /// against a page we control, so the PencilKit canvas and the whole handoff can be
        /// finished and verified before the web app knows this shell exists.
        case harness
    }

    /// Flip this to `.harness` while working on the ink screen itself.
    ///
    /// It shipped as `.harness` while the web app had never heard of this shell. That ended on
    /// 13 Aug 2026: the bolt-on is merged and deployed, so the real app now opens the native
    /// canvas and the harness is a development tool rather than the only page that works.
    ///
    /// There is deliberately no in-app switch. A debug toggle is one more thing that can be left
    /// in the wrong position and ship, and this is a two-character edit followed by a rebuild
    /// that takes seconds.
    static let startTarget: StartTarget = .liveApp

    /// The deployed app. Note there is no localhost option and there cannot usefully be one:
    /// Clerk's production keys only resolve `myhumans.app`, so no authenticated page renders
    /// anywhere else. That constraint already governs the web repo; it governs this one too.
    static let appURL = URL(string: "https://myhumans.app")!

    /// Appended to the standard WKWebView user agent — never replaces it. See the note in
    /// `Bridge.swift` about `tlenv.isIos`.
    static let userAgentSuffix = "MyHumansiOS/1.0"

    /// How long the pen must be up before the FIRST save of a session is sent.
    ///
    /// Short on purpose, and only once: until the web app has committed a record there is
    /// nothing on the server to update, so this is what makes "write two words and walk away"
    /// safe. Every save after it runs on the long interval below.
    static let firstSaveIdleSeconds: TimeInterval = 6

    /// How often a session that keeps being written in sends its drawing onward.
    ///
    /// Three minutes, not seconds. Every send serialises the drawing and crosses into
    /// JavaScript, and the coach feels each one — so the cadence is set by what is needed to
    /// bound loss, not by how fresh the server could theoretically be. The on-device recovery
    /// copy runs on its own faster clock, and the flush on exit is what actually keeps the
    /// record current.
    static let autosaveIntervalSeconds: TimeInterval = 180

    /// How often the drawing is written to the on-device recovery file while writing continues.
    /// Cheap next to a save — no picture, no bridge, no network — so it can run far more often
    /// and is what a crash actually falls back on.
    static let recoveryIntervalSeconds: TimeInterval = 20

    /// The eraser and the highlighter are multiples of the chosen pen width, so picking a pen
    /// width sets all three tools at once and switching between them needs no second thought.
    ///
    /// Large multiples on purpose, and these are the third calibration — each one from Josh
    /// writing with the previous. A highlighter has to be several times the text it marks or it
    /// reads as a second pen, and an eraser at anything near pen width has to TRACE a word to
    /// clear it, which is not what anyone reaches for an eraser to do.
    ///
    /// They also carry the EQUIVALENCE between the three tools, which is why the tool row can
    /// keep one width slot per tool and never need translating: at the same slot, each tool is
    /// already the size that goes with the others. Josh's calibration was that the highlighter
    /// wanted about half again what it had, and the eraser three times — at the finest pen
    /// (1pt) that is a 22.5pt highlighter and a 60pt eraser.
    static let eraserWidthMultiplier: CGFloat = 60
    static let highlighterWidthMultiplier: CGFloat = 22.5

    /// Ceiling on the eraser, independent of the pen it is scaled from. The multiple alone
    /// reaches ~300pt at the widest pen — about a third of the page — which stops being an
    /// eraser and starts being a way to lose a paragraph in one pass.
    static let eraserMaxWidth: CGFloat = 140

    /// Highlighter colour and opacity — a marker laid over words has to leave them readable.
    static let highlighterAlpha: CGFloat = 0.25

    /// The writing page's width in content units, shared by the inline and fullscreen sizes of
    /// the canvas so they are one piece of paper at two magnifications. If the two sizes each
    /// used their own width, strokes written at the wide one would clip at the narrow one — data
    /// intact, but handwriting the coach can no longer see reads as handwriting lost.
    static let inkPageWidth: CGFloat = 1024

    /// Scale factor for the exported PNG, matching the web canvas's `pixelRatio: 2`.
    static let exportScale: CGFloat = 2

    /// Ceiling on the exported PNG's longest edge in pixels. `/api/upload-image` refuses
    /// anything over 15MB, and a very long page at 2x can approach that. Past this the export
    /// scale is reduced rather than the page being cropped — a smaller picture is a cosmetic
    /// loss, a cropped one loses handwriting.
    static let exportMaxPixels: CGFloat = 8000
}
