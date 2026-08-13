import PencilKit
import UIKit

protocol InkCanvasViewControllerDelegate: AnyObject {
    /// `message` is `.inkAutosave` for a debounced tick, `.inkClose` for the Done flush.
    func inkCanvas(
        _ controller: InkCanvasViewController,
        didProduce result: Bridge.InkResult,
        as message: Bridge.OutboundMessage
    )
    func inkCanvasDidDiscard(_ controller: InkCanvasViewController, noteId: String?)
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
/// What it replaces on the web side is not small. `TldrawNoteCanvas.tsx` is 984 lines, and about
/// 600 of them work around problems that do not exist here: the camera lock that stops a resting
/// palm killing a stroke, the hand-rolled two-finger pan that lock made necessary, the coalesced
/// -events mutation, `recoverStuckInteraction()`, the tool dock with its palm guard, and the
/// two-finger double-tap eraser with nine hand-tuned thresholds that were never measured on a
/// device. `PKCanvasView` is a `UIScrollView` and PencilKit owns the input pipeline, so scroll,
/// palm rejection, pressure, tilt and the Pencil's own double-tap all come for free.
final class InkCanvasViewController: UIViewController {

    weak var delegate: InkCanvasViewControllerDelegate?

    private let request: Bridge.OpenInkRequest
    private let canvasView = PKCanvasView()
    private var toolPicker: PKToolPicker?
    private var autosaveTimer: Timer?

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

    init(request: Bridge.OpenInkRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = request.darkMode ? .dark : .light
        view.backgroundColor = pageColor

        configureCanvas()
        configureNavigationBar()
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
            presentLoadFailure()
        } else {
            offerRecoveryIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        growContentIfNeeded()
    }

    // MARK: - Setup

    private var pageColor: UIColor {
        // Matches the web canvas's Background component exactly, so a note written on the iPad
        // and one written in a browser sit side by side without one looking wrong.
        request.darkMode ? UIColor(white: 0x1e / 255, alpha: 1) : .white
    }

    private func configureCanvas() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = pageColor
        canvasView.isOpaque = true
        canvasView.delegate = self

        // Pencil only by default. Every documented failure in this feature's history is a palm
        // or a finger being mistaken for the pen, and this setting removes the entire class:
        // fingers scroll, the Pencil writes, and neither can be confused for the other. The
        // toolbar carries a toggle for anyone without a Pencil to hand.
        canvasView.drawingPolicy = .pencilOnly

        canvasView.alwaysBounceVertical = true
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 4
        canvasView.showsVerticalScrollIndicator = true
        canvasView.showsHorizontalScrollIndicator = false

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

        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(handleDone)
            ),
        ]

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
        InkRecovery.save(canvasView.drawing, noteId: request.noteId)
    }

    /// Offered, never applied silently.
    ///
    /// A recovered drawing may be older than what the web app already holds — an autosave may well
    /// have landed after the last copy was written — so this asks rather than assumes. If the page
    /// already shows exactly what was recovered, there is nothing to ask about and the copy goes
    /// quietly.
    private func offerRecoveryIfNeeded() {
        guard let recovered = InkRecovery.load(noteId: request.noteId) else { return }

        guard recovered.dataRepresentation() != canvasView.drawing.dataRepresentation() else {
            InkRecovery.clear(noteId: request.noteId)
            return
        }

        let alert = UIAlertController(
            title: "Unsaved handwriting found",
            message: "The app closed before this was saved. Put it back on the page?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Put it back", style: .default) { [weak self] _ in
            guard let self else { return }
            self.canvasView.drawing = recovered
            self.growContentIfNeeded()
            // Straight onto the normal autosave path, so this stops being the only copy.
            self.scheduleAutosave()
        })
        let noteId = request.noteId
        alert.addAction(UIAlertAction(title: "Discard it", style: .destructive) { _ in
            InkRecovery.clear(noteId: noteId)
        })
        present(alert, animated: true)
    }

    // MARK: - Page length

    /// Grows the page as the writing approaches the bottom, so it behaves like a pad rather than
    /// a fixed sheet. Never shrinks below what is already written.
    private func growContentIfNeeded() {
        let width = view.bounds.width
        guard width > 0 else { return }

        let screenHeight = max(view.bounds.height, 1)
        let written = canvasView.drawing.bounds.isNull ? 0 : canvasView.drawing.bounds.maxY
        let wanted = max(screenHeight * 2, written + screenHeight)

        if abs(canvasView.contentSize.height - wanted) > 1 || canvasView.contentSize.width != width {
            canvasView.contentSize = CGSize(width: width, height: wanted)
        }
    }

    // MARK: - Actions

    // Resolved through the canvas's responder chain, which is where PencilKit registers its
    // stroke undos. The view controller's own `undoManager` is a different object and would
    // silently do nothing.
    @objc private func handleUndo() { canvasView.undoManager?.undo() }

    @objc private func handleRedo() { canvasView.undoManager?.redo() }

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
            self.autosaveTimer?.invalidate()
            self.canvasView.drawing = PKDrawing()
            InkRecovery.clear(noteId: self.request.noteId)
            self.delegate?.inkCanvasDidDiscard(self, noteId: self.request.noteId)
            self.delegate?.inkCanvasDidFinish(self)
        })
        present(alert, animated: true)
    }

    @objc private func handleDone() {
        autosaveTimer?.invalidate()
        // The flush. Sent before dismissing so the web page has the final state even if the
        // coach immediately backgrounds the app.
        emit(.inkClose)
        // Past the flush the copy is stale, and stale recovery is its own kind of data loss. But
        // a screen that never took ownership of the note must not delete a recovery copy it
        // deliberately refused to offer.
        if !loadFailed { InkRecovery.clear(noteId: request.noteId) }
        delegate?.inkCanvasDidFinish(self)
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(
            withTimeInterval: Config.autosaveIdleSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.emit(.inkAutosave)
        }
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
        InkRecovery.save(drawing, noteId: request.noteId)

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
                didProduce: .empty(noteId: request.noteId),
                as: .inkClose
            )
            return
        }

        delegate?.inkCanvas(self, didProduce: result(for: drawing, png: png), as: .inkClose)
    }

    private func result(for drawing: PKDrawing, png: Data) -> Bridge.InkResult {
        Bridge.InkResult(
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
        let pageWidth = max(canvasView.contentSize.width, bounds.maxX + padding)

        let rect = CGRect(
            x: 0,
            y: max(0, bounds.minY - padding),
            width: pageWidth,
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
