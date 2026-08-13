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

        let ink = InkCanvasViewController(request: request)
        ink.delegate = self
        inkController = ink

        let nav = UINavigationController(rootViewController: ink)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
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
        emit(.inkDiscard, payload: Bridge.InkDiscard(noteId: noteId))
    }

    func inkCanvasDidFinish(_ controller: InkCanvasViewController) {
        // Dismissed from here rather than from the ink controller: it sits inside a navigation
        // controller, so it is not itself the presented view controller, and this shell is.
        dismiss(animated: true)
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

        // mailto: (the celebration email is a real <a href>) and tel: belong to the system.
        if let scheme = url.scheme, ["mailto", "tel", "facetime", "sms"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
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
