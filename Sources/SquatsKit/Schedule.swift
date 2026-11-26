import Foundation

/// When reminders are allowed to run. Off by default: they run whenever you are at the laptop.
public struct Schedule: Equatable {
    public var enabled: Bool
    public var startHour: Int
    public var endHour: Int
    public var weekdaysOnly: Bool

    public init(enabled: Bool = false, startHour: Int = 9, endHour: Int = 18, weekdaysOnly: Bool = true) {
        self.enabled = enabled
        self.startHour = startHour
        self.endHour = endHour
        self.weekdaysOnly = weekdaysOnly
    }

    /// The start hour is included, the end hour is not. Hours may run past midnight (22 to 6).
    /// Equal start and end means all day, so a slip of the stepper cannot silence every reminder.
    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        if weekdaysOnly && calendar.isDateInWeekend(date) { return false }   // the calendar's own weekend
        if startHour == endHour { return true }
        let hour = calendar.component(.hour, from: date)
        return startHour < endHour ? (startHour..<endHour).contains(hour) : hour >= startHour || hour < endHour
    }
}

/// A temporary stop, such as "pause for an hour".
public struct Pause: Equatable {
    public private(set) var until: Date?

    public init(until: Date? = nil) { self.until = until }

    public func isActive(at date: Date) -> Bool { until.map { date < $0 } ?? false }

    public mutating func start(at date: Date, for seconds: TimeInterval) {
        until = date.addingTimeInterval(seconds)
    }

    public mutating func stop() { until = nil }
}
