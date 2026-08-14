import UIKit
import WebKit

/// Breaks the retain cycle WKUserContentController would otherwise create by holding its message
/// handler strongly forever.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {

    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// The shell: one WKWebView that IS the app.
///
/// Every screen, all data access, all authorization and every save path belong to the web app at
/// `myhumans.app`. Feature work ships to Render and appears here instantly — no rebuild, no
/// review. The only thing this controller adds is the bridge: when the page asks, it presents
/// the native ink screen and relays what comes back.
final class WebShellViewController: UIViewController {

    private var webView: WKWebView!
    private var inkController: InkCanvasViewController?

    /// The inline canvas's rectangle as the PAGE reported it, in CSS pixels of the layout
    /// viewport. Kept so its place on screen can be re-derived whenever the web view moves or
    /// rescales underneath it — the keyboard avoiding a focused field, a pinch — without asking
    /// the page to re-measure, which would tell us nothing: `getBoundingClientRect()` returns
    /// the same numbers whether or not the page is zoomed.
    private var inlineCSSRect: CGRect?
    private var scrollObservation: NSKeyValueObservation?

    /// Watched separately from the offset, because a programmatic `setZoomScale` can move the
    /// scale without moving the offset, and KVO delivery order between the two is not promised.
    private var zoomObservation: NSKeyValueObservation?

    /// Auth pop-ups (Microsoft sign-in among them) open via window.open, which WKWebView
    /// surfaces as a request for a new web view. Refusing it shows the coach a button that does
    /// nothing, so a child view is presented and closed when the flow finishes.
    private var popupWebView: WKWebView?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureWebView()
        load(Config.startTarget)
    }

    private func configureWebView() {
        let configuration = WKWebViewConfiguration()

        // Default persistent store: cookies (Clerk's session among them) survive relaunch.
        configuration.websiteDataStore = .default()

        // Appended to the standard UA, never replacing it — tldraw and others key behaviour off
        // the platform UA, and the web app feature-detects the shell via the injected object,
        // not the UA. See Bridge.swift.
        configuration.applicationNameForUserAgent = Config.userAgentSuffix

        // The feature-detection object, present before any page script runs.
        let userScript = WKUserScript(
            source: Bridge.injectedScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(userScript)

        // WKUserContentController retains its handlers strongly, so registering `self` directly
        // is a retain cycle that outlives the controller. Harmless while this is the root view
        // controller and never deallocates — but it stops being harmless the moment anyone
        // presents a second shell, so it is done properly here rather than left as a trap.
        configuration.userContentController.add(
            ScriptMessageProxy(target: self),
            name: Bridge.messageHandlerName
        )

        configuration.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        // The inline canvas is placed from a rectangle the PAGE measured, and that rectangle says
        // nothing about where WebKit is currently showing the viewport or at what magnification.
        // Both live on the scroll view, and both move without the page ever hearing about it:
        // keyboard avoidance and the automatic safe-area inset move the offset, a pinch moves the
        // offset AND the scale. Miss either and the canvas detaches from the page it is
        // pretending to be part of.
        scrollObservation = webView.scrollView.observe(\.contentOffset) { [weak self] _, _ in
            self?.placeInlineInk()
        }
        // Zoom is observed in its own right rather than assumed to ride along with an offset
        // change. A pinch does move both, so this is usually redundant — but a programmatic
        // `setZoomScale` need not touch the offset at all, and nothing promises which of the two
        // KVO notifications lands last. Placing from whichever arrives costs a transform
        // assignment and removes the question.
        zoomObservation = webView.scrollView.observe(\.zoomScale) { [weak self] _, _ in
            self?.placeInlineInk()
        }
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func load(_ target: Config.StartTarget) {
        switch target {
        case .liveApp:
            webView.load(URLRequest(url: Config.appURL))
        case .harness:
            guard let url = Bundle.main.url(forResource: "harness", withExtension: "html") else {
                assertionFailure("harness.html missing from bundle")
                webView.load(URLRequest(url: Config.appURL))
                return
            }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // MARK: - Bridge, outbound

    private func emit<T: Encodable>(_ message: Bridge.OutboundMessage, payload: T) {
        guard let script = Bridge.emitScript(message, payload: payload) else { return }
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                // Never fatal: rule 2 of the bridge. The web side treats a missed autosave the
                // way it treats any other missed tick — the next one carries the full state.
                print("Bridge emit failed for \(message.rawValue): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Ink presentation

    private func presentInk(_ request: Bridge.OpenInkRequest) {
        guard inkController == nil else { return }

        // A frame means the v2 web app wants the canvas IN the page, beside the person's
        // details. No frame is the v1 contract: a modal screen with its own bar.
        if let frame = request.frame {
            let ink = InkCanvasViewController(request: request, mode: .inline)
            ink.delegate = self
            inkController = ink

            addChild(ink)
            // A view controller's root view arrives with a flexible-width/height autoresizing
            // mask, and this one is a plain `addSubview` child of a hierarchy that is otherwise
            // Auto Layout driven — so UIKit would keep re-deriving its frame from the shell's
            // bounds on every rotation and every Stage Manager resize. Frame arithmetic on a
            // view carrying a scale transform is undefined: the derived frame is the ALREADY
            // SCALED rect, so it lands back in `bounds` and the transform scales it a second
            // time. `placeInlineInk()` is the only thing allowed to say where this rectangle
            // is, and the mask has to go or UIKit quietly argues with it.
            ink.view.autoresizingMask = []
            inlineCSSRect = frame
            placeInlineInk()
            // Above the web view, which stays interactive everywhere else — the page renders
            // the buttons, this rectangle is only the paper.
            view.addSubview(ink.view)
            ink.didMove(toParent: self)
            return
        }

        let ink = InkCanvasViewController(request: request, mode: .modal)
        ink.delegate = self
        inkController = ink

        let nav = UINavigationController(rootViewController: ink)
        // The asset-catalog accent does not reliably reach a modally presented bar, and the
        // default systemBlue reads as off-brand next to the app's navy. Named colour, so the
        // dark variant still applies.
        nav.navigationBar.tintColor = UIColor(named: "AccentColor")
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func tearDownInlineInk(_ ink: InkCanvasViewController) {
        inlineCSSRect = nil
        ink.willMove(toParent: nil)
        ink.view.removeFromSuperview()
        ink.removeFromParent()
    }

    /// The page's rectangle, in CSS pixels of the layout viewport, put on screen.
    ///
    /// `getBoundingClientRect()` is measured against the LAYOUT viewport, so the document's own
    /// scroll offset is already out of the numbers the page sends. What is left is the two things
    /// only this side can see — the magnification, and where WebKit is currently showing that
    /// viewport inside the scroll view's content:
    ///
    ///     view = (css + window.scroll) * zoomScale - contentOffset
    ///
    /// `window.scroll` is zero here by construction: every protected page is an `h-dvh` shell
    /// whose only scrollers are elements inside it, so the ROOT scroller has nothing to scroll,
    /// and everything WebKit does — the resting safe-area inset, keyboard avoidance, a pinch —
    /// is the visual viewport moving, which is exactly what `contentOffset` reports. At rest
    /// that leaves `css + adjustedContentInset.top`, which is the status bar the canvas used to
    /// sit over, back when the raw rect was trusted. If a future layout ever lets the DOCUMENT
    /// scroll, the scroll lands in both terms and the canvas rides up by twice it — that is the
    /// assumption to re-check, not the inset one.
    ///
    /// The zoom term is what was missing until August 2026, and its absence was not a small
    /// error. At scale 2 the paper landed a whole rectangle-origin away from the page's own
    /// placeholder at half the size — and that placeholder is an EMPTY div, because this canvas
    /// is meant to cover it completely, so every stroke after a pinch went into nothing at all:
    /// no ink, no autosave, no status change, until the page was left and reopened. Neither side
    /// could recover on its own — the page's re-measure is zoom-invariant, and the offset stops
    /// changing when the gesture ends.
    ///
    /// Scale is applied as a layer transform, never by handing PencilKit a bigger rectangle.
    /// Changing the canvas's bounds runs its `viewDidLayoutSubviews`, which re-fits the zoom,
    /// rewrites `contentSize` and makes PencilKit re-tile — many times a second for the length of
    /// a pinch, which is the expensive work this screen bans anywhere near a live pen. It also
    /// keeps `view.bounds` in the page's own units, which is what the page-width and
    /// content-growth arithmetic on the canvas side already reads it as.
    private func placeInlineInk() {
        guard let rect = inlineCSSRect, let ink = inkController, ink.mode == .inline else { return }
        let scroll = webView.scrollView
        // A canvas collapsed to a point is indistinguishable from one that vanished, so a scale
        // WebKit should never report is not one worth passing on either.
        let zoom = scroll.zoomScale > 0 ? scroll.zoomScale : 1
        let offset = scroll.contentOffset

        // Only on a real size change: this runs on every offset and every zoom notification, and
        // an assignment that dirties layout would put that re-tile back under the pen.
        if ink.view.bounds.size != rect.size {
            ink.view.bounds = CGRect(origin: .zero, size: rect.size)
        }
        ink.view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        // `center` is in this view's space and is untouched by the transform, so it is the one
        // placement that stays correct while the scale changes underneath it. Setting `frame`
        // with a transform in place is undefined, which is why nothing here sets it — and why
        // `presentInk()` clears the autoresizing mask, since that is UIKit setting it for you.
        ink.view.center = CGPoint(x: rect.midX * zoom - offset.x, y: rect.midY * zoom - offset.y)
    }
}

// MARK: - WKScriptMessageHandler (web → native)

extension WebShellViewController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Bridge.messageHandlerName else { return }
        guard
            let body = message.body as? [String: Any],
            let name = body["name"] as? String
        else { return }

        // Unrecognised names fall through silently — the web app may be newer than this shell.
        guard let inbound = Bridge.InboundMessage(name: name, body: body["payload"] ?? [:]) else {
            return
        }

        switch inbound {
        case .openInk(let request):
            presentInk(request)
        case .setFrame(let frame):
            // Layout changed under the inline canvas — fullscreen toggled, sidebar collapsed,
            // rotation. Unanimated: the page's own layout change isn't animated either, and a
            // lagging canvas visibly detaches from the page around it.
            inlineCSSRect = frame
            placeInlineInk()
            inkController?.reassertInput()
        case .setHidden(let hidden):
            // A web dialog needs the screen. The canvas always draws above web content, so
            // without this every dialog on the take-notes screen opened underneath the paper.
            inkController?.view.isHidden = hidden
            if !hidden { inkController?.reassertInput() }
        case .setPrefs(let prefs):
            inkController?.apply(prefs)
            inkController?.reassertInput()
        case .setTool(let tool):
            inkController?.apply(tool: tool)
        case .undo:
            inkController?.undoFromWeb()
        case .redo:
            inkController?.redoFromWeb()
        case .finish:
            inkController?.finishFromWeb()
        case .clearCanvas:
            inkController?.clearFromWeb()
        }
    }
}

// MARK: - InkCanvasViewControllerDelegate (native → web)

extension WebShellViewController: InkCanvasViewControllerDelegate {

    func inkCanvas(
        _ controller: InkCanvasViewController,
        didProduce result: Bridge.InkResult,
        as message: Bridge.OutboundMessage
    ) {
        emit(message, payload: result)
    }

    func inkCanvasDidDiscard(_ controller: InkCanvasViewController, noteId: String?) {
        emit(.inkDiscard, payload: Bridge.InkDiscard(session: controller.session, noteId: noteId))
    }

    func inkCanvas(_ controller: InkCanvasViewController, didSwitchToolTo kind: String) {
        emit(.inkToolChanged, payload: Bridge.InkToolChanged(session: controller.session, kind: kind))
    }

    func inkCanvasDidFailLoad(_ controller: InkCanvasViewController, noteId: String?) {
        // Tell the page so it can fall back to its read-only picture, then take the dead
        // canvas away. An older page ignores the unknown name — rule 2.
        emit(.inkLoadFailed, payload: Bridge.InkLoadFailed(session: controller.session, noteId: noteId))
        inkCanvasDidFinish(controller)
    }

    func inkCanvasDidFinish(_ controller: InkCanvasViewController) {
        switch controller.mode {
        case .inline:
            tearDownInlineInk(controller)
        case .modal:
            // Dismissed from here rather than from the ink controller: it sits inside a
            // navigation controller, so it is not itself the presented view controller, and
            // this shell is.
            dismiss(animated: true)
        }
        inkController = nil
    }
}

// MARK: - WKNavigationDelegate

extension WebShellViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Nothing is torn down here, deliberately. This method is asked WHETHER to navigate; it
        // is never told that one happened, and the branch immediately below says no to some of
        // what it is asked about. The teardown used to run above that branch, so tapping the
        // coachee's email address in the sidebar — a plain <a href="mailto:">, a main-frame
        // action — destroyed the canvas and then cancelled the very navigation that was the
        // reason for destroying it. The page stayed mounted and was never told, so ink.tool,
        // ink.undo, ink.redo and ink.finish all optional-chained through a nil controller: a
        // live-looking toolbar over an empty rectangle, for the rest of the visit. Fragment
        // links, downloads and loads that fail before committing are all the same shape.
        // Teardown now happens in `didCommit`, where the old document is provably gone; the
        // strokes are safe in the meantime because backgrounding banks them too.

        // mailto: (the celebration email is a real <a href>) and tel: belong to the system.
        if let scheme = url.scheme, ["mailto", "tel", "facetime", "sms"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    /// The one moment a real navigation has stopped being hypothetical.
    ///
    /// A commit means the old document is gone, which is the one condition the inline canvas
    /// cannot survive. The page does try to say goodbye — TakeNotesCanvas posts `ink.finish`
    /// from `pagehide` — but that message has to cross into this process while WebKit is
    /// already tearing the document down, so it is a courtesy and not a guarantee. This is the
    /// belt: bank the ink, remove the canvas, let the new document start clean. Same story as
    /// process death.
    ///
    /// The shell starts nothing of its own from here. Whatever is committed now is not the
    /// document the canvas belonged to, so an `ink.*` sent from this point would run in the NEW
    /// page carrying the OLD session tag — which is why the tag exists, and why this stays quiet.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The auth pop-up is handed this same delegate so its redirects can be followed, and
        // every step of a sign-in flow is a main-frame commit in ITS web view. None of them say
        // anything about the page the canvas is sitting on.
        guard webView === self.webView, let ink = inkController, ink.mode == .inline else {
            return
        }
        ink.persistNow()
        tearDownInlineInk(ink)
        inkController = nil
    }
}

// MARK: - Process death

extension WebShellViewController {

    /// WebKit's content process died — low memory, a renderer crash. The page is gone, but the
    /// native canvas would keep floating over the blank web view, eating strokes for a page
    /// that no longer exists. Bank the ink, tear down, reload; the recovery offer on the next
    /// open is the mechanism that was device-tested on day one.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Which web view died matters. The auth pop-up shares this delegate and, being a
        // different site, gets a content process of its own — so its crash can arrive here
        // while the page under the canvas is perfectly alive. Taking a live canvas away because
        // a sign-in window fell over is the same silent no-paper failure the navigation path
        // used to have. Reload whichever one died; only the main one's death goes near the ink.
        if webView === self.webView, let ink = inkController {
            ink.persistNow()
            if ink.mode == .inline { tearDownInlineInk(ink) } else { dismiss(animated: false) }
            inkController = nil
        }
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension WebShellViewController: WKUIDelegate {

    /// window.open — sign-in providers use this. The child shares the parent's configuration
    /// (and so its cookie store), which is what lets the auth cookies land where the main web
    /// view can see them.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popupWebView = popup

        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        popup.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            popup.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            popup.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])

        let nav = UINavigationController(rootViewController: host)
        host.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closePopup)
        )
        present(nav, animated: true)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        closePopup()
    }

    @objc private func closePopup() {
        popupWebView = nil
        presentedViewController?.dismiss(animated: true)
    }

    // JS alert/confirm — the web app uses confirm() for a handful of destructive prompts, and
    // WKWebView drops them silently unless these are implemented.

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}
