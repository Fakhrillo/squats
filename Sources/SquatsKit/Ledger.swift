import Foundation

/// The whole reminder model is one number, `owed`. Every interval at the laptop adds a set, every
/// counted squat subtracts one. A skipped or half-done set just stays owed.
public struct Ledger: Codable, Equatable {
    public var owed = 0
    public var doneToday = 0
    /// Present seconds counted toward the next set.
    public var elapsed: TimeInterval = 0
    /// "yyyy-MM-dd" of the last tick.
    public var day = ""

    public init() {}

    /// Returns true when this tick completed an interval (a set became due).
    /// At most one set per tick, however large `seconds` is.
    public mutating func tick(seconds: TimeInterval, present: Bool, today: String,
                              perSet: Int, interval: TimeInterval, maxOwed: Int) -> Bool {
        if today != day {
            day = today
            owed = 0
            doneToday = 0
            elapsed = 0
        }
        guard present else { return false }
        elapsed += seconds
        guard elapsed >= interval else { return false }
        elapsed = 0
        owed = min(owed + perSet, maxOwed)
        return true
    }

    public mutating func recordSquat() {
        owed = max(0, owed - 1)
        doneToday += 1
    }

    /// A finished set with nothing left owed restarts the countdown.
    public mutating func sessionEnded(reachedTarget: Bool) {
        if reachedTarget && owed == 0 { elapsed = 0 }
    }

    public func target(perSet: Int) -> Int { owed > 0 ? owed : perSet }

    // MARK: What the menu shows

    public var statusText: String {
        switch owed {
        case 0: return "All caught up"
        case 1: return "1 squat owed"
        default: return "\(owed) squats owed"
        }
    }

    /// The label of the main button: exactly what pressing it will ask for.
    public func actionText(perSet: Int) -> String {
        switch owed {
        case 0: return "Do a set of \(perSet)"
        case 1: return "Do 1 squat"
        default: return "Do \(owed) squats"
        }
    }

    /// How far through the current interval the sitting timer is, 0…1.
    public func progress(interval: TimeInterval) -> Double {
        interval > 0 ? min(1, max(0, elapsed / interval)) : 0
    }

    public func noticeText(perSet: Int) -> String {
        let carried = owed - perSet
        return carried > 0 ? "\(owed) squats — \(carried) carried over" : "Time for \(owed) squats"
    }
}

/// Decides when a due set may be announced.
/// - `hold`: wait and announce later (a video call is in progress).
/// - `drop`: forget it (a set is in progress, or reminders are paused or outside working hours;
///   the menu-bar count still shows what is owed).
public struct NoticeGate {
    private var pending = false

    public init() {}

    public mutating func shouldPost(due: Bool, hold: Bool, drop: Bool) -> Bool {
        if due { pending = true }
        if drop { pending = false }
        guard pending, !hold else { return false }
        pending = false
        return true
    }
}
