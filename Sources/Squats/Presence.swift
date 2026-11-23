import CoreGraphics
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
}
