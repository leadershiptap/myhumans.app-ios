import PencilKit
import UIKit

protocol InkCanvasViewControllerDelegate: AnyObject {
    /// `message` is `.inkAutosave` for a debounced tick, `.inkClose` for the flush.
    func inkCanvas(
        _ controller: InkCanvasViewController,
        didProduce result: Bridge.InkResult,
        as message: Bridge.OutboundMessage
    )
    func inkCanvasDidDiscard(_ controller: InkCanvasViewController, noteId: String?)
    /// The incoming drawing would not decode and the canvas refused to open over it.
    func inkCanvasDidFailLoad(_ controller: InkCanvasViewController, noteId: String?)
    func inkCanvasDidFinish(_ controller: InkCanvasViewController)
}

/// The one screen that exists for a reason a browser cannot serve.
///
/// Everything here is deliberately thin. This controller is a pure input device: a drawing comes
/// in, a drawing and a picture go out. It never talks to the database, never talks to Cloudinary,
/// never knows what a Note is, and never fetches an ink image — every ink URL in the app is a
/// cookie-authenticated same-origin request, and staying out of that path is what keeps this
/// shell from needing a second copy of the app's auth.
///
/// Two presentations of the same canvas:
///
///   - `.modal` — full screen with a navigation bar. The v1 behaviour, kept for a web app that
///     has never heard of inline.
///   - `.inline` — embedded in the page at a rectangle the web side reports, beside the
///     person's details. No bar of its own: undo, redo, clear and settings are page-rendered
///     buttons that arrive over the bridge, so the chrome matches the app around it.
///
/// The drawing lives on a fixed-width page (`Config.inkPageWidth` content units) shown
/// fit-to-width at whatever size the canvas currently is. That constant is what makes inline
/// and fullscreen the same piece of paper at two magnifications, instead of two different-width
/// pages that clip each other's strokes.
final class InkCanvasViewController: UIViewController {

    enum Mode { case modal, inline }

    weak var delegate: InkCanvasViewControllerDelegate?

    let mode: Mode
    private let request: Bridge.OpenInkRequest

    /// What the on-device recovery copy is filed under. The web side's draft key when it sent
    /// one — scoped to the person and meeting, existing before the note does — else the note id.
    /// Keying by note id alone filed every brand-new note under one shared "unsaved" slot, and
    /// the next blank page ANYONE opened was offered another person's handwriting.
    private var recoveryKey: String? { request.recoveryKey ?? request.noteId }

    /// The tag stamped on every reply, identifying which open this canvas answers for.
    var session: String? { request.recoveryKey }
    private let canvasView = PKCanvasView()
    private var toolPicker: PKToolPicker?
    private var autosaveTimer: Timer?

    // Preferences, applied at open and updatable live over the bridge.
    private var twoFingerScroll = true
    private var lockZoom = true
    private var pageDark: Bool

    /// The page's width in CONTENT units. At least `Config.inkPageWidth`; wider only when an
    /// incoming drawing already has strokes beyond it, because clipping those visually — even
    /// with the data safe — reads as lost handwriting.
    private var pageWidth: CGFloat = Config.inkPageWidth

    /// Set when the incoming drawing could not be decoded, which DISABLES saving for the rest of
    /// the screen's life.
    ///
    /// This mirrors `didFailToLoad()` on the web canvas and exists for the same reason: a drawing
    /// that fails to load renders as an empty page, and an empty page that saves overwrites real
    /// handwriting with nothing. Failing loudly and refusing to write is the only safe behaviour,
    /// because the coach cannot tell an empty page from a broken one.
    private var loadFailed = false

    /// Guards against a drawing arriving that we then immediately overwrite with an empty one.
    private var hasAppeared = false

    // MARK: - Init

    init(request: Bridge.OpenInkRequest, mode: Mode) {
        self.request = request
        self.mode = mode
        self.pageDark = request.prefs?.darkMode ?? request.darkMode
        super.init(nibName: nil, bundle: nil)
        if mode == .modal { modalPresentationStyle = .fullScreen }
        if let prefs = request.prefs {
            twoFingerScroll = prefs.twoFingerScroll ?? twoFingerScroll
            lockZoom = prefs.lockZoom ?? lockZoom
        } else if mode == .modal {
            // A v1 web app sends no prefs and expects v1 behaviour: one-finger scroll, free
            // pinch. The new guards are defaults for the page that can actually toggle them.
            twoFingerScroll = false
            lockZoom = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = pageDark ? .dark : .light
        view.backgroundColor = pageColor

        configureCanvas()
        if mode == .modal { configureNavigationBar() }
        loadIncomingDrawing()
        observeBackgrounding()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAppeared else { return }
        hasAppeared = true

        // The tool picker needs a first responder that is already in a window, so this cannot
        // move into viewDidLoad.
        let picker = PKToolPicker()
        picker.addObserver(canvasView)
        picker.setVisible(true, forFirstResponder: canvasView)
        canvasView.becomeFirstResponder()
        toolPicker = picker

        if loadFailed {
            if mode == .inline {
                // No alert over an embedded canvas: the page owns this failure. It gets the
                // signal, swaps in its read-only picture, and this dead paper goes away —
                // otherwise the coach is left a live-looking rectangle that eats every stroke.
                delegate?.inkCanvasDidFailLoad(self, noteId: request.noteId)
            } else {
                presentLoadFailure()
            }
        } else {
            offerRecoveryIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyZoomPolicy()
        growContentIfNeeded()
    }

    // MARK: - Setup

    private var pageColor: UIColor {
        // Matches the web canvas's Background component exactly, so a note written on the iPad
        // and one written in a browser sit side by side without one looking wrong.
        pageDark ? UIColor(white: 0x1e / 255, alpha: 1) : .white
    }

    private func configureCanvas() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = pageColor
        canvasView.isOpaque = true
        canvasView.delegate = self

        // Pencil only by default. Every documented failure in this feature's history is a palm
        // or a finger being mistaken for the pen, and this setting removes the entire class:
        // fingers scroll, the Pencil writes, and neither can be confused for the other.
        canvasView.drawingPolicy = .pencilOnly

        canvasView.alwaysBounceVertical = true
        canvasView.showsVerticalScrollIndicator = true
        canvasView.showsHorizontalScrollIndicator = false

        applyScrollPolicy()

        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureNavigationBar() {
        title = request.title

        // Not the word "Done": the coach is contracting the writing surface, not completing
        // anything. The icon mirrors the expand control that opened it.
        let close = UIBarButtonItem(
            image: UIImage(systemName: "arrow.down.right.and.arrow.up.left"),
            style: .done,
            target: self,
            action: #selector(handleDone)
        )
        close.accessibilityLabel = "Close the writing screen"
        navigationItem.leftBarButtonItems = [close]

        let undo = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.backward"),
            style: .plain,
            target: self,
            action: #selector(handleUndo)
        )
        undo.accessibilityLabel = "Undo"

        let redo = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.forward"),
            style: .plain,
            target: self,
            action: #selector(handleRedo)
        )
        redo.accessibilityLabel = "Redo"

        let clear = UIBarButtonItem(
            image: UIImage(systemName: "trash"),
            style: .plain,
            target: self,
            action: #selector(handleClear)
        )
        clear.accessibilityLabel = "Clear page"

        navigationItem.rightBarButtonItems = [clear, redo, undo, fingerToggleItem()]
    }

    private func fingerToggleItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "hand.draw"),
            style: .plain,
            target: self,
            action: #selector(toggleFingerDrawing)
        )
        item.accessibilityLabel = "Draw with a finger"
        return item
    }

    private func loadIncomingDrawing() {
        guard let encoded = request.drawing, !encoded.isEmpty else { return }
        guard
            let data = Data(base64Encoded: encoded),
            let drawing = try? PKDrawing(data: data)
        else {
            loadFailed = true
            return
        }
        canvasView.drawing = drawing
        // Notes written before the fixed page width existed used the device's width as their
        // page. Widen rather than clip: the data would survive clipping, but handwriting the
        // coach can no longer see reads as handwriting lost.
        if !drawing.bounds.isNull {
            pageWidth = max(pageWidth, drawing.bounds.maxX + 24)
        }
    }

    private func presentLoadFailure() {
        let alert = UIAlertController(
            title: "This note can't be opened here",
            message: "It was written in a different editor. Nothing has been lost — open it on a "
                + "computer to see it. Saving is switched off on this screen so it can't be "
                + "overwritten.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Go back", style: .default) { [weak self] _ in
            guard let self else { return }
            self.delegate?.inkCanvasDidFinish(self)
        })
        present(alert, animated: true)
    }

    // MARK: - Preferences

    func apply(_ prefs: Bridge.InkPrefs) {
        if let twoFinger = prefs.twoFingerScroll { twoFingerScroll = twoFinger }
        if let lock = prefs.lockZoom { lockZoom = lock }
        if let dark = prefs.darkMode, dark != pageDark {
            pageDark = dark
            overrideUserInterfaceStyle = dark ? .dark : .light
            view.backgroundColor = pageColor
            canvasView.backgroundColor = pageColor
        }
        applyScrollPolicy()
        applyZoomPolicy()
    }

    /// Two-finger-only scrolling stops a resting finger moving the page — the same class of
    /// accident `drawingPolicy = .pencilOnly` removes for drawing.
    private func applyScrollPolicy() {
        canvasView.panGestureRecognizer.minimumNumberOfTouches = twoFingerScroll ? 2 : 1
    }

    /// Fit-to-width is the resting state. With the zoom locked, it is the ONLY state — the pinch
    /// gesture has nowhere to go, so the canvas cannot be accidentally resized mid-session.
    private var appliedInitialFit = false
    /// The width the current fit was computed for. Recomputing on every layout pass is what
    /// made this a loop.
    private var fittedWidth: CGFloat = 0

    /// Setting `zoomScale` or `contentSize` triggers `layoutSubviews`, which called straight
    /// back into here — a feedback loop that ran while the pen was on the glass. It now does
    /// nothing at all unless the view's width has actually changed, which happens on rotation,
    /// on entering or leaving fullscreen, and never during a stroke.
    private func applyZoomPolicy() {
        let width = view.bounds.width
        guard width > 0, pageWidth > 0 else { return }
        guard abs(width - fittedWidth) > 0.5 || !appliedInitialFit else { return }
        fittedWidth = width

        let fit = width / pageWidth
        canvasView.minimumZoomScale = fit
        canvasView.maximumZoomScale = lockZoom ? fit : fit * 3
        // Fit-to-width is the resting state, locked or not: an unlocked canvas that opened at
        // scale 1 showed a third of the page for no reason a coach could see.
        canvasView.zoomScale = fit
        appliedInitialFit = true
    }

    // MARK: - Crash recovery

    /// The case this protects against is iOS terminating a backgrounded app. Nothing runs, no
    /// delegate fires, and whatever had not yet crossed the bridge is simply gone. Going into the
    /// background is the last moment there is to do anything about it.
    private func observeBackgrounding() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(persistForRecovery),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func persistForRecovery() {
        // A screen that could not open its own note must not write a recovery copy of the blank
        // page it is showing. That is the same overwrite `loadFailed` exists to prevent.
        guard !loadFailed else { return }
        InkRecovery.save(canvasView.drawing, noteId: recoveryKey)
    }

    /// Offered, never applied silently.
    ///
    /// A recovered drawing may be older than what the web app already holds — an autosave may well
    /// have landed after the last copy was written — so this asks rather than assumes. If the page
    /// already shows exactly what was recovered, there is nothing to ask about and the copy goes
    /// quietly.
    private func offerRecoveryIfNeeded() {
        guard let recovered = InkRecovery.load(noteId: recoveryKey) else { return }

        guard recovered.dataRepresentation() != canvasView.drawing.dataRepresentation() else {
            InkRecovery.clear(noteId: recoveryKey)
            return
        }

        let alert = UIAlertController(
            title: "Unsaved handwriting found",
            message: "The app closed before this was saved. Put it back on the page?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            guard let self else { return }
            self.canvasView.drawing = recovered
            if !recovered.bounds.isNull {
                self.pageWidth = max(self.pageWidth, recovered.bounds.maxX + 24)
            }
            self.applyZoomPolicy()
            self.growContentIfNeeded()
            // Straight onto the normal autosave path, so this stops being the only copy.
            self.scheduleAutosave()
        })
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.confirmDiscardOfRecovery()
        })
        present(alert, animated: true)
    }

    /// Discarding is the one irreversible button on that alert: the copy being thrown away is, by
    /// definition, the only one left. Everything else here can be undone by opening the note
    /// again, so this is the only place a second tap is worth asking for.
    private func confirmDiscardOfRecovery() {
        let noteId = recoveryKey
        let alert = UIAlertController(
            title: "Discard the unsaved handwriting?",
            message: "This is the only copy. Once it's gone it can't be brought back.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Keep it", style: .cancel) { [weak self] _ in
            // Cancelling must leave the copy exactly where it was, and put the choice back rather
            // than silently dropping it — otherwise a mis-tap costs the note anyway.
            self?.offerRecoveryIfNeeded()
        })
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { _ in
            InkRecovery.clear(noteId: noteId)
        })
        present(alert, animated: true)
    }

    // MARK: - Page length

    /// Grows the page as the writing approaches the bottom, so it behaves like a pad rather than
    /// a fixed sheet. Never shrinks below what is already written. All arithmetic is in CONTENT
    /// units; `contentSize` is in view points, hence the multiplications by the zoom scale.
    private func growContentIfNeeded() {
        let zoom = canvasView.zoomScale
        guard zoom > 0, view.bounds.width > 0 else { return }

        let visibleContentHeight = max(view.bounds.height / zoom, 1)
        let written = canvasView.drawing.bounds.isNull ? 0 : canvasView.drawing.bounds.maxY
        let wantedContentHeight = max(visibleContentHeight * 2, written + visibleContentHeight)

        let wanted = CGSize(width: pageWidth * zoom, height: wantedContentHeight * zoom)
        // GROW only, and only meaningfully. Assigning contentSize is a layout pass, and this
        // runs on every drawing change — a jittering value here is felt as a stuttering pen.
        let needsTaller = wanted.height - canvasView.contentSize.height > 8
        let widthChanged = abs(canvasView.contentSize.width - wanted.width) > 0.5
        if needsTaller || widthChanged {
            canvasView.contentSize = CGSize(
                width: wanted.width,
                height: max(wanted.height, canvasView.contentSize.height),
            )
        }
    }

    // MARK: - Actions (modal bar, and the bridge's inline equivalents)

    // Resolved through the canvas's responder chain, which is where PencilKit registers its
    // stroke undos. The view controller's own `undoManager` is a different object and would
    // silently do nothing.
    @objc private func handleUndo() { canvasView.undoManager?.undo() }

    @objc private func handleRedo() { canvasView.undoManager?.redo() }

    /// The page's undo/redo buttons, arriving over the bridge.
    func undoFromWeb() { canvasView.undoManager?.undo() }
    func redoFromWeb() { canvasView.undoManager?.redo() }

    /// The tool picker follows first responder, and any tap into a web text field takes it.
    /// Called by the shell whenever the canvas should own input again — a frame update, a
    /// preference change — and cheap to call when it already does.
    func reassertInput() {
        guard hasAppeared, !canvasView.isFirstResponder else { return }
        canvasView.becomeFirstResponder()
    }

    /// The shell is about to tear this canvas down outside the normal flows — the web content
    /// process died, or the page navigated away for real. Bank the ink first.
    func persistNow() {
        guard !loadFailed else { return }
        InkRecovery.save(canvasView.drawing, noteId: recoveryKey)
    }

    @objc private func toggleFingerDrawing() {
        canvasView.drawingPolicy = canvasView.drawingPolicy == .pencilOnly ? .anyInput : .pencilOnly
    }

    @objc private func handleClear() {
        let alert = UIAlertController(
            title: "Throw this note away?",
            message: "The handwriting and the saved note are both deleted. This can't be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.cancelAutosave()
            self.canvasView.drawing = PKDrawing()
            InkRecovery.clear(noteId: self.recoveryKey)
            self.delegate?.inkCanvasDidDiscard(self, noteId: self.request.noteId)
            self.delegate?.inkCanvasDidFinish(self)
        })
        present(alert, animated: true)
    }

    /// The page already deleted the record through its own Clear flow — it asked its own
    /// question, and this canvas must not ask a second one or send anything back. Blank the
    /// page and drop the recovery copy so the deleted drawing cannot offer itself back.
    func clearFromWeb() {
        cancelAutosave()
        canvasView.drawing = PKDrawing()
        InkRecovery.clear(noteId: recoveryKey)
        // And the undo stack. Leaving it meant one Undo resurrected the deleted drawing, and
        // the autosave that followed committed it into a brand-new note.
        canvasView.undoManager?.removeAllActions()
    }

    @objc private func handleDone() {
        cancelAutosave()
        // The flush. Sent before dismissing so the web page has the final state even if the
        // coach immediately backgrounds the app.
        emit(.inkClose)
        // Past the flush the copy is stale, and stale recovery is its own kind of data loss. But
        // a screen that never took ownership of the note must not delete a recovery copy it
        // deliberately refused to offer.
        if !loadFailed { InkRecovery.clear(noteId: recoveryKey) }
        delegate?.inkCanvasDidFinish(self)
    }

    /// The inline teardown, on `ink.finish` from the page.
    ///
    /// Same flush as Done with one deliberate difference: the recovery copy is KEPT. The emit
    /// crosses into JavaScript on a page that is tearing itself down, and there is no way to
    /// confirm it arrived — so the on-device copy stays as the net. The next open of this note
    /// compares and quietly discards it when the page already has everything, which is the
    /// mechanism that was device-tested on day one.
    func finishFromWeb() {
        cancelAutosave()
        if !loadFailed { InkRecovery.save(canvasView.drawing, noteId: recoveryKey) }
        emit(.inkClose)
        delegate?.inkCanvasDidFinish(self)
    }

    // MARK: - Autosave

    /// The ceiling. Deliberately NOT reset by new strokes — that is the whole point of it —
    /// and deliberately a timer rather than an inline emit.
    private var autosaveCeilingTimer: Timer?

    /// Called on every drawing change, so it must stay cheap.
    ///
    /// An earlier version emitted INLINE here once the ceiling had passed. `emit` rasterises
    /// the whole page through `renderPNG` — synchronously, on the main thread — so that put a
    /// full-page render inside the pen's own event handling, mid-stroke, every few seconds of
    /// continuous writing. Strokes were dropped, and the harder the coach wrote the worse it
    /// got. Both paths are timers now: nothing expensive happens while the pen is down.
    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(
            withTimeInterval: Config.autosaveIdleSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.fireAutosave()
        }

        // Steady writing with sub-idle gaps would postpone the debounce forever, and everything
        // behind the bridge is only as fresh as the last message. This one is armed once and
        // left alone until it fires.
        if autosaveCeilingTimer == nil {
            autosaveCeilingTimer = Timer.scheduledTimer(
                withTimeInterval: Config.autosaveMaxSeconds,
                repeats: false
            ) { [weak self] _ in
                self?.fireAutosave()
            }
        }
    }

    private func cancelAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        autosaveCeilingTimer?.invalidate()
        autosaveCeilingTimer = nil
    }

    private func fireAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        autosaveCeilingTimer?.invalidate()
        autosaveCeilingTimer = nil
        emit(.inkAutosave)
    }

    /// Builds a result and hands it to the delegate.
    ///
    /// Two things stop content ever being sent, each of which would otherwise destroy something:
    ///   - the incoming drawing failed to load, so what is on screen is not the note;
    ///   - the picture could not be rendered, because every surface in the app displays ink from
    ///     the picture, so saving strokes without one produces a note nothing can show.
    ///
    /// An empty page is different: `ink.close` still fires, carrying `isEmpty`. The web page
    /// always learns the screen was dismissed, and the rule about what an emptied canvas means
    /// stays in the one place it already lives rather than being duplicated here.
    private func emit(_ message: Bridge.OutboundMessage) {
        guard case .inkAutosave = message else {
            emitFinal(message)
            return
        }
        guard !loadFailed else { return }

        let drawing = canvasView.drawing
        guard !drawing.bounds.isNull, !drawing.bounds.isEmpty else { return }
        guard let png = renderPNG(for: drawing) else { return }

        // Written before the message goes out rather than after: if anything downstream of here
        // fails, the strokes are still on disk.
        InkRecovery.save(drawing, noteId: recoveryKey)

        delegate?.inkCanvas(self, didProduce: result(for: drawing, png: png), as: .inkAutosave)
    }

    private func emitFinal(_ message: Bridge.OutboundMessage) {
        guard case .inkClose = message else { return }

        // A failed load must not report a blank page as the note's new state — that is exactly
        // the overwrite this screen refuses to perform. Say nothing instead.
        guard !loadFailed else { return }

        let drawing = canvasView.drawing
        guard
            !drawing.bounds.isNull,
            !drawing.bounds.isEmpty,
            let png = renderPNG(for: drawing)
        else {
            delegate?.inkCanvas(
                self,
                didProduce: .empty(session: request.recoveryKey, noteId: request.noteId),
                as: .inkClose
            )
            return
        }

        delegate?.inkCanvas(self, didProduce: result(for: drawing, png: png), as: .inkClose)
    }

    private func result(for drawing: PKDrawing, png: Data) -> Bridge.InkResult {
        Bridge.InkResult(
            session: request.recoveryKey,
            noteId: request.noteId,
            drawing: drawing.dataRepresentation().base64EncodedString(),
            png: png.base64EncodedString(),
            isEmpty: false
        )
    }

    // MARK: - Export

    /// Flattens the handwriting into the PNG every surface in the app actually renders.
    ///
    /// PencilKit hands back a transparent image, so the page colour is composited in here — the
    /// web canvas exports with `background: true` and the two have to agree, or a note written on
    /// the iPad shows as transparent-on-whatever wherever it appears.
    private func renderPNG(for drawing: PKDrawing) -> Data? {
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty else { return nil }

        let padding: CGFloat = 24
        let exportWidth = max(pageWidth, bounds.maxX + padding)

        let rect = CGRect(
            x: 0,
            y: max(0, bounds.minY - padding),
            width: exportWidth,
            height: bounds.height + padding * 2
        )
        guard rect.width > 0, rect.height > 0 else { return nil }

        // Step the scale down rather than cropping if the page is very long. A smaller picture
        // is a cosmetic loss; a cropped one silently loses handwriting, and the upload route
        // refuses anything over 15MB.
        let longestEdge = max(rect.width, rect.height)
        let scale = min(Config.exportScale, max(1, Config.exportMaxPixels / longestEdge))

        let strokes = drawing.image(from: rect, scale: scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.pngData { context in
            pageColor.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            strokes.draw(in: CGRect(origin: .zero, size: rect.size))
        }
    }
}

// MARK: - PKCanvasViewDelegate

extension InkCanvasViewController: PKCanvasViewDelegate {

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard hasAppeared else { return }
        growContentIfNeeded()
        scheduleAutosave()
    }
}
