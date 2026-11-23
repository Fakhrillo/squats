import AVFoundation
import SwiftUI
import Vision

/// Built-in camera → Vision body pose → one `PoseFrame` per processed frame.
/// The camera runs only between `start()` and `stop()`. Nothing is written anywhere.
///
/// `@unchecked Sendable`: `busy` is confined to `queue`, and `onFrame` is set once before `start()`
/// and only ever called on the main actor.
public final class PoseCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum StartResult { case running, denied, noCamera }

    /// Width / height of the `.hd1280x720` preset.
    public static let aspect = 16.0 / 9.0

    public let session = AVCaptureSession()

    /// Nearest person in view, or a frame with no joints when nobody is seen.
    public var onFrame: (@MainActor (PoseFrame) -> Void)?

    private let queue = DispatchQueue(label: "squats.camera")
    private var busy = false   // read and written only on `queue`

    /// Asks for camera permission on first use.
    public func start() async -> StartResult {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first, !device.isSuspended,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return .noCamera }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return .noCamera }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.addInput(input)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false   // Vision sees the true image; only the preview is mirrored
        }
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
        return .running
    }

    public func stop() {
        queue.async { self.session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard !busy else { return }   // one Vision request in flight; frames arriving meanwhile are dropped
        busy = true
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        Task {
            let observations = (try? await DetectHumanBodyPoseRequest().perform(on: sampleBuffer, orientation: nil)) ?? []
            let people = observations.map { PoseFrame($0, time: time, aspect: Self.aspect) }
            let frame = PoseFrame.nearest(people) ?? PoseFrame(time: time)
            await MainActor.run { self.onFrame?(frame) }
            self.queue.async { self.busy = false }
        }
    }
}

/// Mirrored camera preview at 16:9 with a dot on every joint of confidence ≥ 0.3.
public struct CameraPreview: View {
    private let session: AVCaptureSession
    private let frame: PoseFrame?

    public init(session: AVCaptureSession, frame: PoseFrame?) {
        self.session = session
        self.frame = frame
    }

    public var body: some View {
        PreviewLayerView(session: session, tick: frame?.time)
            .overlay {
                Canvas { context, size in
                    for joint in frame?.joints ?? [] where joint.confidence >= 0.3 {
                        let x = (1 - joint.x / PoseCamera.aspect) * size.width
                        let y = (1 - joint.y) * size.height
                        context.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)),
                                     with: .color(.green))
                    }
                }
            }
            .aspectRatio(PoseCamera.aspect, contentMode: .fit)
            .background(.black)
    }
}

private struct PreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let tick: TimeInterval?   // changes every frame, so mirroring is applied once the connection exists

    func makeNSView(context: Context) -> NSView {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let connection = (view.layer as? AVCaptureVideoPreviewLayer)?.connection,
              connection.isVideoMirroringSupported, !connection.isVideoMirrored else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
