import Foundation
import Testing
@testable import SquatsKit

/// A fixed calendar so the tests do not depend on where or when they run.
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US")
    return c
}

/// 2026-11-25 is a Wednesday, 2026-11-28 a Saturday.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func hours(_ start: Int, _ end: Int, weekdaysOnly: Bool = true) -> Schedule {
    Schedule(enabled: true, startHour: start, endHour: end, weekdaysOnly: weekdaysOnly)
}

@Test func withoutWorkingHoursRemindersAlwaysRun() {
    #expect(Schedule().isActive(at: at(28, 3), calendar: utc))          // Saturday, 03:00
}

@Test func workingHoursStartOnTheHourAndEndBeforeTheLast() {
    let s = hours(9, 18)
    #expect(!s.isActive(at: at(25, 8, 59), calendar: utc))
    #expect(s.isActive(at: at(25, 9), calendar: utc))
    #expect(s.isActive(at: at(25, 17, 59), calendar: utc))
    #expect(!s.isActive(at: at(25, 18), calendar: utc))
}

@Test func weekendsAreOffUnlessAllowed() {
    #expect(!hours(9, 18).isActive(at: at(28, 10), calendar: utc))
    #expect(hours(9, 18, weekdaysOnly: false).isActive(at: at(28, 10), calendar: utc))
}

@Test func hoursMayRunPastMidnight() {
    let s = hours(22, 6, weekdaysOnly: false)
    #expect(s.isActive(at: at(25, 23), calendar: utc))
    #expect(s.isActive(at: at(25, 5, 59), calendar: utc))
    #expect(!s.isActive(at: at(25, 6), calendar: utc))
    #expect(!s.isActive(at: at(25, 12), calendar: utc))
}

@Test func equalStartAndEndMeansAllDay() {      // a slip of the stepper must not silence every reminder
    #expect(hours(9, 9).isActive(at: at(25, 3), calendar: utc))
}

@Test func pauseLastsUntilItsEnd() {
    var p = Pause()
    #expect(!p.isActive(at: at(25, 10)))
    p.start(at: at(25, 10), for: 3600)
    #expect(p.isActive(at: at(25, 10, 59)))
    #expect(!p.isActive(at: at(25, 11)))
    #expect(p.until == at(25, 11))
    p.start(at: at(25, 10), for: 3600); p.stop()
    #expect(!p.isActive(at: at(25, 10, 30)))
}
