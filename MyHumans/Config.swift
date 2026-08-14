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

        /// The bundled stub page, `Resources/harness.html`. Drives the v2 INLINE contract — a
        /// measured rectangle, a draft-key `recoveryKey`, prefs and a page-rendered tool row —
        /// against a page we control, and still carries one button that opens with no frame,
        /// which is the only way left to exercise the v1 full-screen modal flow now that the
        /// real app never asks for it.
        ///
        /// It promised "all four" bridge messages until August 2026, by which point that was
        /// true of nothing: the harness sent no frame at all, so flipping this switch quietly
        /// tested the modal path while the shipping path was inline. The phrase is paraphrased
        /// here rather than quoted whole, so the grep that hunts the old claim stays clean.
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

    /// The eraser width a Pencil squeeze uses before the page has ever sent one.
    ///
    /// Only reachable when the coach squeezes without having touched the eraser in the tool row
    /// first, which is the common case on a fresh note. Matches the page's default slot, and is
    /// corrected by the page's own message a moment later either way.
    ///
    /// This block used to OPEN with "the eraser and the highlighter are multiples of the chosen
    /// pen width, so picking a pen width sets all three tools at once" — the exact belief that
    /// turned a squeeze into a 1.5pt eraser. It survived the fix and sat directly above the
    /// constant that exists BECAUSE it is false. A stale comment on a working line is worse than
    /// no comment: it is what the next reader reasons from before they read the code.
    static let fallbackEraserWidth: CGFloat = 55

    // Tool sizes are NOT computed here, and this is the note that says so. A plain `//` on
    // purpose: it documents an ABSENCE, and a `///` block with no declaration beneath it is
    // documentation for no symbol at all — the compiler simply drops it, and the reader is left
    // guessing whether it belongs to the constant above or the one below.
    //
    // They were ratios of the pen (and multipliers before that), and both were wrong for the
    // same reason: the sizes that feel right are not a constant multiple of one another, and a
    // multiplier that overshoots an ink's limit is silently clamped — so slots collapsed onto
    // one width with nothing to show why. The page now sends the width it wants for the tool
    // it is asking for, one readable table per tool, and this side clamps it into whatever the
    // chosen ink will actually accept.

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
