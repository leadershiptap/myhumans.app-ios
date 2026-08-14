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
    /// The Pencil's own gesture changed tools; the page's toolbar needs to agree.
    func inkCanvas(_ controller: InkCanvasViewController, didSwitchToolTo kind: String)
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

    /// The note this canvas is writing into RIGHT NOW, which is not the same thing as the note
    /// it opened on.
    ///
    /// A canvas outlives the record it started with: the page's own Clear deletes the note and
    /// says so with `ink.clearCanvas`, and every stroke after that belongs to a note that does
    /// not exist yet. Leaving the deleted id on the messages was not untidiness — the page drops
    /// anything naming the note it just cleared, for the rest of that page's life, so every
    /// autosave AND the closing flush were thrown away in silence with nothing on screen saying
    /// so. The only thing that rescued the handwriting was the draft the page writes as it
    /// unmounts: the save path was running on the backup.
    ///
    /// The session tag beside it stays `request.recoveryKey` throughout: that says which OPEN
    /// this reply answers for, and a Clear does not end the open.
    private var currentNoteId: String?

    /// What the on-device recovery copy is filed under. The web side's draft key when it sent
    /// one — scoped to the person and meeting, existing before the note does — else the note id.
    /// Keying by note id alone filed every brand-new note under one shared "unsaved" slot, and
    /// the next blank page ANYONE opened was offered another person's handwriting.
    ///
    /// Deliberately NOT derived from `currentNoteId`, which now goes nil on a Clear. The copy on
    /// disk belongs to the writing session, not to the record: move the key mid-session and what
    /// was already banked is stranded under a name nothing looks for again, while what follows
    /// lands in the shared `__unsaved__` slot this key exists to keep handwriting out of.
    private let recoveryKey: String?

    /// The tag stamped on every reply, identifying which open this canvas answers for.
    var session: String? { request.recoveryKey }

    /// What the page's tool row last asked for, and what a squeeze toggles back to. The Pencil's
    /// gesture is a TOGGLE, so it has to remember what it toggled away from.
    private var currentTool = Bridge.InkTool(["kind": "pen", "color": "#0f172a", "width": 1.8])
    private var toolBeforeEraser: Bridge.InkTool?

    /// The last width the page asked for, PER TOOL.
    ///
    /// Sizes live in the page now — one table per tool — and they are not multiples of each
    /// other, so this side cannot work out an eraser width from a pen width. Remembering what
    /// it was last told is the only way a squeeze can switch tools without inventing a size.
    private var lastWidthByKind: [String: CGFloat] = [:]
    private let canvasView = PKCanvasView()
    private var toolPicker: PKToolPicker?
    private var autosaveTimer: Timer?

    // Preferences, applied at open and updatable live over the bridge.
    private var twoFingerScroll = true
    private var lockZoom = true
    private var pageDark: Bool
    /// Apple's floating palette. Off inline — it is a separate system window roughly 748x122pt
    /// with no size API, so over an embedded canvas it covers the page's own chrome.
    private var systemToolPicker: Bool

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

    /// The drawing an unanswered recovery offer is holding, and the fact that one is on screen.
    ///
    /// It lives here rather than only inside the alert's Restore closure because the rest of this
    /// screen has to be able to SEE that a question is outstanding. While the alert is up the
    /// canvas is still showing the OLDER drawing the page sent — that is the whole reason there
    /// was something to ask about — so anything that writes the canvas to disk in that window
    /// destroys the very thing being offered. See `bankRecovery()`.
    private var pendingRecovery: PKDrawing?

    /// The coach was asked and said discard.
    ///
    /// A decision, not a deletion. Deleting the file alone could never hold: the file is derived
    /// from the canvas, the canvas is untouched by a discard, and the next writer puts it
    /// straight back. Released the first time the drawing changes, because from that moment
    /// there is new handwriting worth protecting and it is not the handwriting that was thrown
    /// away.
    private var recoveryDeclined = false

    // MARK: - Init

    init(request: Bridge.OpenInkRequest, mode: Mode) {
        self.request = request
        self.mode = mode
        // Seeded from the open and owned by the canvas from here on: `request` is a let, and the
        // note it names can be deleted while this canvas stays up and keeps taking strokes.
        self.currentNoteId = request.noteId
        // Fixed for the canvas's life on purpose — see the property.
        self.recoveryKey = request.recoveryKey ?? request.noteId
        self.pageDark = request.prefs?.darkMode ?? request.darkMode
        self.systemToolPicker = request.prefs?.systemToolPicker ?? (mode == .modal)
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
        canvasView.becomeFirstResponder()
        applySystemToolPicker()
        // PencilKit derives the scroll pan's touch count from `drawingPolicy` and rewrites it
        // whenever it reconfigures its input pipeline — attaching a picker and taking first
        // responder are both such moments. Re-assert after them, not only before.
        applyScrollPolicy()

        if loadFailed {
            if mode == .inline {
                // No alert over an embedded canvas: the page owns this failure. It gets the
                // signal, swaps in its read-only picture, and this dead paper goes away —
                // otherwise the coach is left a live-looking rectangle that eats every stroke.
                delegate?.inkCanvasDidFailLoad(self, noteId: currentNoteId)
            } else {
                presentLoadFailure()
            }
        } else {
            offerRecoveryIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // PencilKit rewrites the pan's touch count whenever it reconfigures; layout runs after
        // every such point, including each inline frame change.
        applyScrollPolicy()
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
        configurePencilGestures()
        // Start on the same tool the page's row shows as selected, so the first stroke matches
        // the highlighted button rather than whatever PencilKit last remembered.
        apply(tool: Bridge.InkTool(["kind": "pen", "color": "#0f172a", "width": 1.8]))

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
        if let showPicker = prefs.systemToolPicker, showPicker != systemToolPicker {
            systemToolPicker = showPicker
            applySystemToolPicker()
        }
        if let dark = prefs.darkMode, dark != pageDark {
            pageDark = dark
            overrideUserInterfaceStyle = dark ? .dark : .light
            view.backgroundColor = pageColor
            canvasView.backgroundColor = pageColor
        }
        applyScrollPolicy()
        applyZoomPolicy()
    }

    /// The Pencil's own barrel gestures — double-tap, and squeeze on a Pencil Pro.
    ///
    /// PencilKit wires these up itself ONLY through `PKToolPicker`, and this canvas hides the
    /// picker because it cannot be sized to fit the page. So the interaction is installed
    /// directly, and the gesture toggles the same tools the page's row does.
    private func configurePencilGestures() {
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        canvasView.addInteraction(interaction)
    }

    /// Eraser ↔ whatever was in hand before it. The classic double-tap behaviour, kept for the
    /// squeeze too because it is the one people reach for mid-sentence.
    fileprivate func togglePencilTool() {
        let next: Bridge.InkTool
        if currentTool.kind == "eraser" {
            next = toolBeforeEraser ?? Bridge.InkTool(["kind": "pen", "color": "#0f172a", "width": 1.8])
        } else {
            // The ERASER's own width, never the pen's. Carrying `currentTool.width` across is
            // what made a squeeze produce a 1.5pt eraser: pen widths and eraser widths come
            // from different tables in the page and are nothing like each other, so reusing one
            // for the other is not a small error — it is two orders of magnitude.
            //
            // The page confirms this a moment later with its own `ink.tool`; this is what
            // stops the gesture feeling wrong in between.
            next = Bridge.InkTool([
                "kind": "eraser",
                "color": currentTool.color,
                "width": Double(lastWidthByKind["eraser"] ?? Config.fallbackEraserWidth),
            ])
        }
        apply(tool: next)
        // The page's row has to agree, or the gesture silently desynchronises the toolbar from
        // the tool actually in hand and the row is what looks broken.
        delegate?.inkCanvas(self, didSwitchToolTo: next.kind)
    }

    /// Apple's palette, on demand only.
    private func applySystemToolPicker() {
        guard hasAppeared else { return }
        if systemToolPicker {
            let picker = toolPicker ?? PKToolPicker()
            picker.addObserver(canvasView)
            picker.setVisible(true, forFirstResponder: canvasView)
            toolPicker = picker
        } else {
            toolPicker?.setVisible(false, forFirstResponder: canvasView)
            toolPicker = nil
        }
    }

    /// Clamps into the range PencilKit will actually honour for a given ink.
    ///
    /// Each ink type has its own `validWidthRange`, and a width outside it is silently pinned
    /// to the nearest end — which is why a multiplied highlighter could come out looking the
    /// same as the pen. Clamping here means an out-of-range request degrades to the widest
    /// stroke the ink allows rather than to no visible change at all.
    private func clamped(_ width: CGFloat, for inkType: PKInkingTool.InkType) -> CGFloat {
        let range = inkType.validWidthRange
        return min(max(width, range.lowerBound), range.upperBound)
    }

    /// The widest fixed-width ink that can carry this width, else the one with the range.
    ///
    /// Nothing here hard-codes Apple's numbers: it asks each ink what it accepts. That is the
    /// lesson from two rounds of widths that silently clamped — `validWidthRange` is the only
    /// thing that knows, and it is cheap to ask.
    private func highlighterInk(for width: CGFloat) -> PKInkingTool.InkType {
        if #available(iOS 17.0, *) {
            if PKInkingTool.InkType.monoline.validWidthRange.contains(width) { return .monoline }
        }
        return .marker
    }

    /// What the page's own tool row picked.
    func apply(tool: Bridge.InkTool) {
        currentTool = tool
        lastWidthByKind[tool.kind] = CGFloat(tool.width)
        if tool.kind != "eraser" { toolBeforeEraser = tool }
        // Only a sanity bound. The real limit is each ink's own `validWidthRange`, applied
        // per-tool below, because that is the one that silently pins a width and looks like a
        // bug rather than a limit.
        let width = CGFloat(max(0.5, min(200, tool.width)))
        switch tool.kind {
        case "eraser":
            // The page's own number for this slot — see `NATIVE_TOOL_SIZES` there. Derived from
            // nothing on this side, which is the whole rule: the line that used to stand here
            // said "four times the pen" for two releases after the multiplying stopped, and a
            // squeeze that took the pen's width at its word shipped a 1.5pt eraser to a coach
            // who then had to trace every word to clear it.
            let eraserWidth = width
            if #available(iOS 16.4, *) {
                canvasView.tool = PKEraserTool(.bitmap, width: eraserWidth)
            } else {
                canvasView.tool = PKEraserTool(.bitmap)
            }

        case "marker":
            // A highlighter is yellow, see-through, and WIDER than the words it marks —
            // otherwise it is just a second pen. The colour is the tool's, not the palette's:
            // picking "red highlighter" is not a thing anyone means.
            //
            // Which ink carries it is decided at runtime rather than assumed, because assuming
            // is what went wrong twice. `.monoline` is the ideal — a constant width, so the
            // stroke ignores both pressure and how the Pencil is HELD, and a marker's
            // edge-on-versus-point-on behaviour is exactly what Josh did not want. But its
            // valid width range turned out to be too narrow for a highlighter: every slot
            // clamped onto the same ceiling, so all four came out identical and thin.
            //
            // So: monoline while it can actually carry the width, and the marker, which has the
            // range, once it cannot. Tilt response is the price of a highlighter you can see,
            // and only at the widths where there is no alternative.
            let highlighterWidth = width
            let highlighterColour = UIColor(hex: "#FDE047")
                .withAlphaComponent(Config.highlighterAlpha)
            canvasView.tool = PKInkingTool(
                highlighterInk(for: highlighterWidth),
                color: highlighterColour,
                width: clamped(highlighterWidth, for: highlighterInk(for: highlighterWidth))
            )

        default:
            // Constant width, no pressure response. Josh: whatever the tool says is what should
            // come out, and a stroke that thins because the hand relaxed reads as a glitch
            // rather than as expression. `.monoline` is exactly that ink; on anything older the
            // pen is the closest available and still honours the chosen width.
            if #available(iOS 17.0, *) {
                canvasView.tool = PKInkingTool(
                    .monoline,
                    color: UIColor(hex: tool.color),
                    width: clamped(width, for: .monoline)
                )
            } else {
                canvasView.tool = PKInkingTool(
                    .pen, color: UIColor(hex: tool.color), width: clamped(width, for: .pen)
                )
            }
        }
        // Assigning a tool re-resolves the input pipeline, which resets the pan touch count.
        applyScrollPolicy()
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
    /// And the page width it was computed against. A fit is the ratio of the two, and watching
    /// only the view's half of it is how the Restore case below slipped through.
    private var fittedPageWidth: CGFloat = 0

    /// Setting `zoomScale` or `contentSize` triggers `layoutSubviews`, which called straight
    /// back into here — a feedback loop that ran while the pen was on the glass. So this still
    /// does nothing unless one of the two numbers the fit is made of has actually moved.
    ///
    /// The view's width moves on rotation, on entering or leaving fullscreen, and never during a
    /// stroke. `pageWidth` moves when a drawing arrives wider than the page, and the second of
    /// those moments — tapping Restore on a recovery copy written before the fixed page width
    /// existed — used to be swallowed here: the page got wider, the view did not, so the canvas
    /// kept the fit for the narrower page and the restored handwriting ran off the right-hand
    /// edge, with `lockZoom` pinning min and max to that stale fit so no pinch could reach it.
    ///
    /// Widening the guard cannot revive the loop. Both remembered values are written below
    /// BEFORE anything that dirties layout, and layout has no way to move `pageWidth` in any
    /// case: it is written only where a drawing arrives, never from `bounds`, `zoomScale` or
    /// `contentSize`, and `growContentIfNeeded()` only ever reads it.
    private func applyZoomPolicy() {
        let width = view.bounds.width
        guard width > 0, pageWidth > 0 else { return }
        let sameFit = abs(width - fittedWidth) <= 0.5 && abs(pageWidth - fittedPageWidth) <= 0.5
        guard !sameFit || !appliedInitialFit else { return }
        fittedWidth = width
        fittedPageWidth = pageWidth

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

    /// The one door to the recovery file. Nothing on this screen writes it any other way.
    ///
    /// Three refusals, each of which was a real way to lose handwriting:
    ///
    ///   - `loadFailed` — a screen that could not open its own note must not write a recovery
    ///     copy of the blank page it is showing. The same overwrite `loadFailed` exists to
    ///     prevent.
    ///   - `pendingRecovery` — an offer is up and unanswered, and the file IS what is being
    ///     offered. The canvas is holding the OLDER drawing the page sent, so a write here
    ///     replaces the offer with it — or deletes it, via `InkRecovery.save`'s empty branch,
    ///     when the page sent nothing at all. The alert itself survives that, because it holds
    ///     the recovered drawing in memory; what does not survive is iOS terminating the app
    ///     while it is backgrounded. The next open then compares the page's drawing against a
    ///     file that now holds the same thing, clears it silently, and the coach never learns
    ///     there had been anything to put back.
    ///   - `recoveryDeclined` — the coach saw the offer and said discard. Nothing has been
    ///     written since, so the canvas holds exactly what the page sent and the page still has
    ///     it: there is nothing here for a copy to be a net for, and re-deriving one would be
    ///     answering the question on the coach's behalf.
    ///
    /// Neither of the last two weakens the rule that a finished session keeps its copy. They are
    /// the two states in which the canvas is provably not carrying anything the page lacks.
    private func bankRecovery() {
        guard !loadFailed, pendingRecovery == nil, !recoveryDeclined else { return }
        InkRecovery.save(canvasView.drawing, noteId: recoveryKey)
    }

    /// Kept as its own method because it is a notification selector — `observeBackgrounding()`
    /// registers it by name, and `#selector` will not resolve a call site that has been inlined.
    @objc private func persistForRecovery() {
        bankRecovery()
    }

    /// Offered, never applied silently.
    ///
    /// A recovered drawing may be older than what the web app already holds — an autosave may well
    /// have landed after the last copy was written — so this asks rather than assumes. If the page
    /// already shows exactly what was recovered, there is nothing to ask about and the copy goes
    /// quietly.
    private func offerRecoveryIfNeeded() {
        // Cleared on the way in, so every path out of here leaves it honest — including the two
        // early returns below. `pendingRecovery` stops every writer on this screen, and this
        // method is re-entered from "Keep it", where it is already set. One re-offer that finds
        // nothing left to offer would strand the flag and switch crash protection off for the
        // rest of the session: a returning copy traded for a losable one, which is worse.
        pendingRecovery = nil

        guard let recovered = InkRecovery.load(noteId: recoveryKey) else { return }

        guard recovered.dataRepresentation() != canvasView.drawing.dataRepresentation() else {
            InkRecovery.clear(noteId: recoveryKey)
            return
        }

        // Held on the controller from the moment the question goes up, not just captured by the
        // Restore closure. A question nobody has answered yet is a state this whole screen has to
        // respect — the app can be backgrounded and then killed by iOS, or the page can tear this
        // canvas down, while the alert is on screen, and every one of those paths used to write
        // the canvas over the copy the alert was offering.
        pendingRecovery = recovered

        let alert = UIAlertController(
            title: "Unsaved handwriting found",
            message: "The app closed before this was saved. Put it back on the page?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            guard let self else { return }
            // Answered, so the writers are free again — and what they write from here is the
            // drawing the coach just accepted, which is the same thing the file already holds.
            // Cleared before the assignment below, because that assignment fires the drawing
            // delegate and everything downstream of it expects the question to be settled.
            //
            // The strokes come from the closure's own copy, not from `pendingRecovery`. Reading
            // them back through an optional would make Restore a silent no-op the day anything
            // clears the flag first, and a Restore that does nothing is the one outcome this
            // alert must never produce.
            self.pendingRecovery = nil
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
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            guard let self else { return }
            // Record the DECISION, then delete the file. Deleting the file was all this used to
            // do, and it did not survive the walk to the door: the page sends `ink.finish` on
            // every unmount and `finishFromWeb` re-derives the copy from the canvas, so the
            // thing just discarded came back from the same session. The flag is what makes
            // Discard mean discard; it lifts the moment there is new handwriting, which is
            // something the coach never asked to throw away.
            self.recoveryDeclined = true
            self.pendingRecovery = nil
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
        guard hasAppeared else { return }
        if !canvasView.isFirstResponder { canvasView.becomeFirstResponder() }
        // Unconditional: taking first responder re-resolves PencilKit's input pipeline and
        // resets the pan touch count, so the two must never be separated.
        applyScrollPolicy()
    }

    /// The shell is about to tear this canvas down outside the normal flows — the web content
    /// process died, or the page navigated away for real. Bank the ink first.
    func persistNow() {
        bankRecovery()
    }

    @objc private func toggleFingerDrawing() {
        canvasView.drawingPolicy = canvasView.drawingPolicy == .pencilOnly ? .anyInput : .pencilOnly
        // `drawingPolicy` is where PencilKit derives the pan touch count from, so any
        // assignment to it must be followed by this.
        applyScrollPolicy()
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
            self.delegate?.inkCanvasDidDiscard(self, noteId: self.currentNoteId)
            self.delegate?.inkCanvasDidFinish(self)
        })
        present(alert, animated: true)
    }

    /// The page already deleted the record through its own Clear flow — it asked its own
    /// question, and this canvas must not ask a second one or send anything back. Blank the
    /// page and drop the recovery copy so the deleted drawing cannot offer itself back.
    ///
    /// What the canvas is left as afterwards is a note that has never been saved, because that
    /// is what it now is.
    func clearFromWeb() {
        canvasView.drawing = PKDrawing()
        InkRecovery.clear(noteId: recoveryKey)
        // And the undo stack. Leaving it meant one Undo resurrected the deleted drawing, and
        // the autosave that followed committed it into a brand-new note.
        canvasView.undoManager?.removeAllActions()
        // And the note's identity. The record is gone, so anything written from here belongs to a
        // note that does not exist yet — and the page refuses every message that names the one it
        // just deleted, silently, for the rest of that page's life. Writing on after a Clear
        // therefore reached the server through no live path at all, with the status line showing
        // nothing wrong. Nil is simply the truth, and it is what a blank new note sends anyway.
        //
        // `recoveryKey` deliberately does not follow this — see its declaration.
        currentNoteId = nil
        // Back onto the first-save path, because a first save is what the next one is. The page
        // will not mint a record without a picture, and `emit` only renders one while this is
        // false — left set, every autosave after a Clear crossed with an empty PNG and was turned
        // away with "Could not render the handwriting yet". It also restores the short idle fuse,
        // so "write two words and walk away" is as safe on this note as it was on the first.
        hasSavedOnce = false
        // LAST, not first. Assigning `drawing` above calls back into `canvasViewDrawingDidChange`,
        // which re-arms both timers — so cancelling on the way in left the deleted note's clocks
        // running over a blank page. Nothing between here and there can fire in the meantime.
        cancelAutosave()
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
    ///
    /// The keep goes through `bankRecovery()`, which is that same net minus the two states where
    /// the canvas is provably carrying nothing the page lacks. This is the line that would
    /// otherwise re-derive a copy the coach had just discarded: the page sends `ink.finish` on
    /// every unmount, and the take-notes effect re-runs on a meeting or category change, so the
    /// round trip can happen within seconds of the alert. Today the reconcile on the next open
    /// usually catches that — the file and the page hold the same drawing — but "usually" is
    /// resting on `dataRepresentation()` being byte-stable across a decode, which nothing here
    /// establishes. A session that wrote so much as one stroke still leaves its copy behind,
    /// because a stroke is what lifts the decline.
    func finishFromWeb() {
        cancelAutosave()
        bankRecovery()
        emit(.inkClose)
        delegate?.inkCanvasDidFinish(self)
    }

    // MARK: - Autosave

    /// The long interval. Deliberately NOT reset by new strokes — that is the whole point of
    /// it — and deliberately a timer rather than an inline emit.
    private var autosaveCeilingTimer: Timer?
    /// The cheap on-device copy, on its own faster clock.
    private var recoveryTimer: Timer?
    /// Until the web app has a record, there is nothing on the server to update — so the first
    /// save runs on a short fuse and carries a picture, and every one after it does not.
    private var hasSavedOnce = false

    /// Called on every drawing change, so it must stay cheap.
    ///
    /// An earlier version emitted INLINE here once the ceiling had passed. `emit` rasterises
    /// the whole page through `renderPNG` — synchronously, on the main thread — so that put a
    /// full-page render inside the pen's own event handling, mid-stroke, every few seconds of
    /// continuous writing. Strokes were dropped, and the harder the coach wrote the worse it
    /// got. Both paths are timers now: nothing expensive happens while the pen is down.
    private func scheduleAutosave() {
        // The on-device copy first, because it is the cheap one and the one a crash falls back
        // on. Armed once and left alone, so continuous writing cannot postpone it.
        if recoveryTimer == nil {
            recoveryTimer = Timer.scheduledTimer(
                withTimeInterval: Config.recoveryIntervalSeconds,
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                self.recoveryTimer = nil
                self.persistForRecovery()
            }
        }

        // The FIRST save of a session runs on a short idle fuse: until the web app has minted a
        // record there is nothing on the server to update, and "write two words and walk away"
        // has to be safe.
        if !hasSavedOnce {
            autosaveTimer?.invalidate()
            autosaveTimer = Timer.scheduledTimer(
                withTimeInterval: Config.firstSaveIdleSeconds,
                repeats: false
            ) { [weak self] _ in
                self?.fireAutosave()
            }
            return
        }

        // After that: a long interval, armed once and never reset by new strokes. Each send
        // serialises the whole drawing and crosses into JavaScript, and the coach feels it — so
        // the cadence is what bounds loss, not what keeps the server maximally fresh. The flush
        // on the way out is what actually makes the record current.
        if autosaveCeilingTimer == nil {
            autosaveCeilingTimer = Timer.scheduledTimer(
                withTimeInterval: Config.autosaveIntervalSeconds,
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
        recoveryTimer?.invalidate()
        recoveryTimer = nil
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

        // The PICTURE is the expensive half — a full-page raster, composite and PNG compress,
        // all on the main thread. The web app only needs one to MINT a record; after that it
        // updates the drawing and refreshes the picture on its own slower schedule, and the
        // flush on the way out always carries a fresh one. So the periodic saves send none, and
        // the coach stops feeling a render every time they pause.
        let png: String
        if hasSavedOnce {
            png = ""
        } else {
            guard let first = renderPNG(for: drawing) else { return }
            png = first.base64EncodedString()
        }
        hasSavedOnce = true

        // Written before the message goes out rather than after: if anything downstream of here
        // fails, the strokes are still on disk. Through the one door not because this call can
        // reach an unanswered offer — no timer can be armed while a modal alert is eating the
        // strokes that would arm it — but because a single direct `InkRecovery.save` left on the
        // write path is how the invariant stops being one.
        bankRecovery()

        delegate?.inkCanvas(
            self,
            didProduce: Bridge.InkResult(
                session: request.recoveryKey,
                noteId: currentNoteId,
                drawing: drawing.dataRepresentation().base64EncodedString(),
                png: png,
                isEmpty: false
            ),
            as: .inkAutosave
        )
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
                didProduce: .empty(session: request.recoveryKey, noteId: currentNoteId),
                as: .inkClose
            )
            return
        }

        delegate?.inkCanvas(self, didProduce: result(for: drawing, png: png), as: .inkClose)
    }

    private func result(for drawing: PKDrawing, png: Data) -> Bridge.InkResult {
        Bridge.InkResult(
            session: request.recoveryKey,
            noteId: currentNoteId,
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
        // A discard was a decision about the copy that was on disk, not a standing instruction to
        // stop protecting this note. New handwriting is new handwriting: it is not the thing that
        // was thrown away, nobody has been asked about it, and it deserves the same net as any
        // other session's.
        recoveryDeclined = false
        scheduleAutosave()
    }

    /// The page grows on pen-lift, not per stroke.
    ///
    /// `contentSize` is not an independent property once the canvas is zoomed — the scroll view
    /// derives it from the zoomed content view, and PencilKit re-tiles its ink renderer against
    /// it. Writing it mid-stroke made two owners fight over the same value on every drawing
    /// change, and reading `drawing.bounds` to compute it unions every stroke in the note, on
    /// every stroke. Both belong at the one moment the answer can have meaningfully changed.
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard hasAppeared else { return }
        growContentIfNeeded()
    }
}


// MARK: - UIPencilInteractionDelegate

extension InkCanvasViewController: UIPencilInteractionDelegate {

    /// Double-tap on the barrel. Honours the coach's system setting where it maps onto a tool
    /// this canvas actually has: there is no colour palette here to show, and `ignore` means
    /// they turned the gesture off deliberately.
    @available(iOS 17.5, *)
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        togglePencilTool()
    }

    /// Squeeze, on a Pencil Pro.
    @available(iOS 17.5, *)
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        // Only on the way out of the gesture, or the tool flips twice per squeeze.
        guard squeeze.phase == .ended else { return }
        guard UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        togglePencilTool()
    }

    /// The pre-17.5 double-tap callback. Still the only one that fires on older systems.
    @available(iOS, introduced: 12.1, deprecated: 17.5)
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        togglePencilTool()
    }
}
