// Throwaway recorder: logs joint coordinates of real squats so thresholds come from measurement.
// Writes numbers only, never images. Deleted in Task 8.
import AppKit
import SquatsKit
import SwiftUI

@main
struct PoseSpikeApp: App {
    var body: some Scene {
        WindowGroup("Pose recorder") { RecorderView() }
    }
}

@MainActor
final class Recorder: ObservableObject {
    static let labels = ["squats-1m", "squats-1.5m", "squats-2m", "idle", "walk"]

    let camera = PoseCamera()
    let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                        ? CommandLine.arguments[1] : NSTemporaryDirectory())

    @Published var frame: PoseFrame?
    @Published var label = Recorder.labels[0]
    @Published var status = "Starting camera…"
    @Published var done: Set<String> = []
    @Published var busy = false

    private var lines: [String]?   // non-nil while recording

    init() {
        camera.onFrame = { [weak self] frame in
            self?.frame = frame
            self?.lines?.append(frame.csvLine)
        }
        Task {
            switch await camera.start() {
            case .running: status = "Ready. Pick a clip and press Record."
            case .denied: status = "Camera access denied (System Settings → Privacy & Security → Camera)."
            case .noCamera: status = "Built-in camera not available. Is the lid closed?"
            }
        }
    }

    func record() {
        let label = label
        busy = true
        Task {
            for n in (1...5).reversed() {
                status = "\(label): get in position… \(n)"
                try? await Task.sleep(for: .seconds(1))
            }
            NSSound(named: "Glass")?.play()
            lines = [PoseFrame.csvHeader]
            for n in (1...25).reversed() {
                status = "\(label): RECORDING — \(n) s left"
                try? await Task.sleep(for: .seconds(1))
            }
            NSSound(named: "Glass")?.play()
            let text = (lines ?? []).joined(separator: "\n") + "\n"
            lines = nil
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try text.write(to: directory.appendingPathComponent(label + ".csv"), atomically: true, encoding: .utf8)
                done.insert(label)
                status = "Saved \(label).csv"
            } catch {
                status = "Could not save: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    var readout: String {
        guard let f = frame else { return "no frames yet" }
        func c(_ j: Joint?) -> String { j.map { String(format: "%.2f", $0.confidence) } ?? " -- " }
        let shoulders = f.sample(minConfidence: 0)
            .map { String(format: "shoulder y %.3f   width %.3f", $0.y, $0.width) } ?? "shoulders not in view"
        return "\(shoulders)\nconfidence   nose \(c(f.nose))   neck \(c(f.neck))   "
            + "shoulders \(c(f.leftShoulder))/\(c(f.rightShoulder))   hips \(c(f.leftHip))/\(c(f.rightHip))"
    }
}

struct RecorderView: View {
    @StateObject private var recorder = Recorder()

    var body: some View {
        VStack(spacing: 12) {
            CameraPreview(session: recorder.camera.session, frame: recorder.frame)
            Text(recorder.status).font(.title).bold()
            Text(recorder.readout).font(.system(.body, design: .monospaced))
            HStack {
                Picker("Clip", selection: $recorder.label) {
                    ForEach(Recorder.labels, id: \.self) { name in
                        Text(recorder.done.contains(name) ? "\(name) ✓" : name).tag(name)
                    }
                }
                .frame(width: 260)
                Button("Record") { recorder.record() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.busy)
            }
        }
        .padding()
        .frame(width: 760)
    }
}
