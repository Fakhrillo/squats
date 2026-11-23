import AVFoundation
import Testing
@testable import SquatsKit

// These use a capture session with no inputs: it can run, but never touches the camera.

@Test func aLateStartAfterStopLeavesTheCameraOff() {
    // The window was closed while the permission prompt was still up; `start()` then finishes.
    let camera = PoseCamera()
    camera.stop()
    camera.run()
    camera.queue.sync {}
    #expect(!camera.session.isRunning)
}

@Test func runStartsAndStopStopsTheSession() {
    let camera = PoseCamera()
    camera.run(); camera.queue.sync {}
    #expect(camera.session.isRunning)
    camera.stop(); camera.queue.sync {}
    #expect(!camera.session.isRunning)
}
