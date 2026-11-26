import AppKit
import SquatsKit
import SwiftUI

/// The floating window for one set. The camera runs only while it is open.
@MainActor
final class SquatWindow: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var session: SquatSession?

    init(model: AppModel) { self.model = model }

    func show() {
        if let window {   // already open: bring it forward
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let session = SquatSession(model: model) { [weak self] in self?.window?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SquatView(session: session)))
        window.title = "Squats"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.appearance = NSAppearance(named: .darkAqua)   // the bar under the camera matches it
        window.isReleasedWhenClosed = false
        window.delegate = self
        Self.centre(window)
        self.window = window
        self.session = session
        model.sessionOpen = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.start()
    }

    /// The middle of the screen you are working on. `NSWindow.center()` is not it: it sits above
    /// the middle by design, and here it ran before SwiftUI had given the content its size.
    static func centre(_ window: NSWindow) {
        if let size = window.contentViewController?.view.fittingSize { window.setContentSize(size) }
        guard let visible = (NSScreen.main ?? window.screen)?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                      y: visible.midY - window.frame.height / 2))
    }

    func windowWillClose(_ notification: Notification) {   // every way of closing ends up here
        session?.finish()
        session = nil
        window = nil
    }
}

/// One set: feeds camera frames to the tracker and publishes what the screen shows.
@MainActor
final class SquatSession: ObservableObject {
    enum CameraState { case starting, running, denied, noCamera }

    /// What the tracker says about the latest frame.
    struct Live {
        var phase = SquatTracker.Phase.searching
        var framing: Framing?
        /// How large the figure would look from the spot `framing` asks for (1 when it is good).
        var sizeAtGoodSpot = 1.0
        var stillProgress = 0.0
        /// How far down, as a share of the depth that counts: 1 is the target line.
        var depth = 0.0
        var deepEnough = false
        /// Seconds since counting first started.
        var seconds = 0
    }

    struct Summary {
        let squats, seconds, doneToday, stillOwed: Int
    }

    let camera = PoseCamera()
    /// Fixed when the window opens; squats that come due mid-set do not raise it.
    let target: Int
    let close: () -> Void
    let figure = FigureSmoother()

    @Published private(set) var frame: PoseFrame?
    @Published private(set) var live = Live()
    @Published private(set) var count = 0
    @Published private(set) var cameraState = CameraState.starting
    // Each of these goes up by one when its moment happens; the views animate on the change.
    @Published private(set) var reachedGoodSpot = 0
    @Published private(set) var started = 0
    @Published private(set) var cameUpShort = 0
    /// Set when the target is reached: the window shows it, then closes.
    @Published private(set) var summary: Summary?

    var doneToday: Int { model.ledger.doneToday }

    private let model: AppModel
    private let tuning: SquatTracker.Tuning
    private var tracker: SquatTracker
    private var startedAt: TimeInterval?
    private let soundOn = UserDefaults.standard.bool(forKey: "soundOn")
    /// Nobody in view this long: close, so a set you were called away from does not leave the
    /// camera on.
    private static let abandonAfter: TimeInterval = 60
    private var finished = false

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        target = model.ledger.target(perSet: model.perSet)
        var tuning = SquatTracker.Tuning()
        let depth = UserDefaults.standard.double(forKey: "depth")
        tuning.up *= depth / tuning.down   // keep the up/down ratio when the depth slider moves
        tuning.down = depth
        self.tuning = tuning
        tracker = SquatTracker(tuning: tuning)
    }

    func start() {
        camera.onFrame = { [weak self] frame in self?.handle(frame) }
        Task {
            switch await camera.start() {
            case .running: cameraState = .running
            case .denied: cameraState = .denied
            case .noCamera: cameraState = .noCamera
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        camera.stop()
        model.sessionOpen = false
        model.sessionEnded(reachedTarget: count >= target)
    }

    func handle(_ frame: PoseFrame) {
        guard !finished else { return }
        self.frame = frame
        guard count < target else { return }
        let was = (phase: tracker.phase, framing: tracker.framing, shallow: tracker.shallowDips)
        let completedRep = tracker.add(frame)
        if tracker.unseenFor > Self.abandonAfter {
            close()
            return
        }
        if tracker.phase == .counting, was.phase != .counting {
            if startedAt == nil { startedAt = frame.time }
            started += 1
            play("Pop")
        } else if tracker.phase == .calibrating, tracker.framing == .good, was.framing != .good {
            reachedGoodSpot += 1
        }
        if tracker.shallowDips > was.shallow { cameUpShort += 1 }
        let seconds = startedAt.map { Int(frame.time - $0) } ?? 0
        live = Live(phase: tracker.phase, framing: tracker.framing, sizeAtGoodSpot: sizeAtGoodSpot(frame),
                    stillProgress: tracker.stillProgress, depth: max(0, tracker.drop) / tuning.down,
                    deepEnough: tracker.isDeepEnough, seconds: seconds)
        guard completedRep else { return }
        count += 1
        model.recordSquat()
        guard count == target else {
            play("Tink")
            return
        }
        play("Glass")
        camera.stop()   // the set is done: the green light goes off while the summary is up
        summary = Summary(squats: count, seconds: seconds, doneToday: model.ledger.doneToday,
                          stillOwed: model.ledger.owed)
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !finished { close() }   // already closed by hand: `close` would hit a newer window
        }
    }

    /// Distance goes as one over shoulder width, so the steps still to take say how much smaller
    /// (or larger) the person will look once they have taken them.
    private func sizeAtGoodSpot(_ frame: PoseFrame) -> Double {
        guard let width = frame.sample(minConfidence: tuning.minConfidence)?.width else { return 1 }
        let metres = tuning.widthAtOneMetre / width
        switch tracker.framing {
        case .tooClose(let steps)?: return metres / (metres + steps * tuning.stepMetres)
        case .tooFar(let steps)?: return metres / max(0.1, metres - steps * tuning.stepMetres)
        default: return 1
        }
    }

    private func play(_ name: String) {
        if soundOn { NSSound(named: name)?.play() }
    }
}
