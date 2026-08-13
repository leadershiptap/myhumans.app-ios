import CoreGraphics
import Foundation

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

    /// How long the pen must be up before an autosave is sent to the web page.
    ///
    /// Faster than the web canvas's 4s commit gate on purpose: this message only crosses into
    /// JavaScript, and the web side then applies its own commit schedule on top. Sending sooner
    /// costs nothing and shortens the window in which a force-quit loses strokes.
    static let autosaveIdleSeconds: TimeInterval = 1.5

    /// Scale factor for the exported PNG, matching the web canvas's `pixelRatio: 2`.
    static let exportScale: CGFloat = 2

    /// Ceiling on the exported PNG's longest edge in pixels. `/api/upload-image` refuses
    /// anything over 15MB, and a very long page at 2x can approach that. Past this the export
    /// scale is reduced rather than the page being cropped — a smaller picture is a cosmetic
    /// loss, a cropped one loses handwriting.
    static let exportMaxPixels: CGFloat = 8000
}
