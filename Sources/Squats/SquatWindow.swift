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
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.session = session
        model.sessionOpen = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.start()
    }

    func windowWillClose(_ notification: Notification) {   // every way of closing ends up here
        session?.finish()
        session = nil
        window = nil
    }
}

@MainActor
final class SquatSession: ObservableObject {
    enum CameraState { case starting, running, denied, noCamera }

    let camera = PoseCamera()
    /// Fixed when the window opens; squats that come due mid-set do not raise it.
    let target: Int
    let close: () -> Void

    @Published private(set) var frame: PoseFrame?
    @Published private(set) var count = 0
    @Published private(set) var phase = SquatTracker.Phase.searching
    @Published private(set) var cameraState = CameraState.starting

    private let model: AppModel
    private var tracker: SquatTracker
    private let soundOn = UserDefaults.standard.bool(forKey: "soundOn")
    private var finished = false

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        target = model.ledger.target(perSet: model.perSet)
        var tuning = SquatTracker.Tuning()
        let depth = UserDefaults.standard.double(forKey: "depth")
        tuning.up *= depth / tuning.down   // keep the up/down ratio when the depth slider moves
        tuning.down = depth
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

    private func handle(_ frame: PoseFrame) {
        guard !finished else { return }
        self.frame = frame
        guard count < target else { return }
        let completedRep = tracker.add(frame)
        phase = tracker.phase
        guard completedRep else { return }
        count += 1
        model.recordSquat()
        if count == target {
            play("Glass")
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                close()
            }
        } else {
            play("Tink")
        }
    }

    private func play(_ name: String) {
        if soundOn { NSSound(named: name)?.play() }
    }
}

private struct SquatView: View {
    @ObservedObject var session: SquatSession

    var body: some View {
        VStack(spacing: 12) {
            switch session.cameraState {
            case .denied:
                Text("Camera access is off for Squats.").font(.headline)
                Button("Open Camera Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            case .noCamera:
                Text("Built-in camera not available. Is the lid closed?").font(.headline)
            case .starting, .running:
                CameraPreview(session: session.camera.session, frame: session.frame)
                Text("\(session.count) / \(session.target)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(status).foregroundStyle(.secondary)
            }
            Button("Done for now") { session.close() }
        }
        .padding()
        .frame(width: 360)
    }

    private var status: String {
        if session.count >= session.target { return "Done!" }
        switch session.phase {
        case .searching: return "Step back until your head and shoulders are in frame"
        case .calibrating: return "Stand still…"
        case .counting: return "Keep going"
        }
    }
}
