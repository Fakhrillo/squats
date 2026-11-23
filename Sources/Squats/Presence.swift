import CoreGraphics
import CoreMediaIO
import Foundation

/// Signals for "is the person at the laptop". None of them use this app's camera.
enum Presence {
    /// Seconds since the last keyboard or mouse input. Reads system counters, never the events.
    static func idleSeconds() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        return kinds
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    /// True when any camera is running in some process: the "in a video call" signal.
    /// Also true for this app's own camera session, so callers skip it while the squat window is open.
    static func cameraInUseElsewhere() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &address, 0, nil,
                                                   UInt32(MemoryLayout<UInt32>.size), &used, &running)
            return status == 0 && running != 0
        }
    }
}
