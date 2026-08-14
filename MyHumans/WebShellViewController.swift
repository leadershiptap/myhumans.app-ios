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

    /// The inline canvas's rectangle as the PAGE reported it, in CSS pixels. Kept so the view
    /// frame can be re-derived when the web view scrolls underneath it — the keyboard avoiding
    /// a focused field is the common case — without asking the page to re-measure.
    private var inlineCSSRect: CGRect?
    private var scrollObservation: NSKeyValueObservation?

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
        // The inline canvas is positioned from CSS coordinates, and those live in the scroll
        // view's content space. Whenever WebKit moves that space — keyboard avoidance, the
        // automatic safe-area inset, a programmatic scroll — the canvas must move with it or
        // it visibly detaches from the page it is pretending to be part of.
        scrollObservation = webView.scrollView.observe(\.contentOffset) { [weak self] _, _ in
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
            inlineCSSRect = frame
            ink.view.frame = viewFrame(forCSSRect: frame)
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

    /// CSS pixels → this view's points.
    ///
    /// A CSS point is a coordinate in the scroll view's CONTENT space, and the content sits at
    /// `-contentOffset` in the view. With the automatic safe-area inset the resting offset is
    /// `-adjustedContentInset.top`, so trusting the raw rect placed the canvas one status bar
    /// too high — over the strip's own buttons. Subtracting the live offset handles the resting
    /// case, the keyboard case and any programmatic scroll with one formula.
    private func viewFrame(forCSSRect rect: CGRect) -> CGRect {
        let offset = webView.scrollView.contentOffset
        return rect.offsetBy(dx: -offset.x, dy: -offset.y)
    }

    private func placeInlineInk() {
        guard let rect = inlineCSSRect, let ink = inkController, ink.mode == .inline else { return }
        ink.view.frame = viewFrame(forCSSRect: rect)
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

        // A real navigation replaces the document, and the SPA's ink.finish never fires for
        // one — the page that would send it is being torn down by WebKit itself. Same story
        // as process death: bank the ink, remove the canvas, let the new page start clean.
        if navigationAction.targetFrame?.isMainFrame == true,
           let ink = inkController, ink.mode == .inline {
            ink.persistNow()
            tearDownInlineInk(ink)
            inkController = nil
        }

        // mailto: (the celebration email is a real <a href>) and tel: belong to the system.
        if let scheme = url.scheme, ["mailto", "tel", "facetime", "sms"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }
}

// MARK: - Process death and real navigation

extension WebShellViewController {

    /// WebKit's content process died — low memory, a renderer crash. The page is gone, but the
    /// native canvas would keep floating over the blank web view, eating strokes for a page
    /// that no longer exists. Bank the ink, tear down, reload; the recovery offer on the next
    /// open is the mechanism that was device-tested on day one.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let ink = inkController {
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
