import Foundation
import Testing
@testable import SquatsKit

private extension Ledger {
    /// n ticks of 30 s with the spec defaults; returns how many reported a set due.
    @discardableResult mutating func run(_ n: Int, present: Bool = true, today: String = "2026-11-23",
                                         perSet: Int = 10, minutes: Double = 30, maxOwed: Int = 30) -> Int {
        (0..<n).filter { _ in tick(seconds: 30, present: present, today: today,
                                   perSet: perSet, interval: minutes * 60, maxOwed: maxOwed) }.count
    }
    mutating func squats(_ n: Int) { for _ in 0..<n { recordSquat() } }
}

// Mutating calls stay outside #expect.
@Test func accruesOneSetPerThirtyPresentMinutes() {
    var l = Ledger()
    let early = l.run(59); #expect(early == 0); #expect(l.owed == 0)
    let due = l.run(1);    #expect(due == 1);   #expect(l.owed == 10); #expect(l.elapsed == 0)
}

@Test func absenceDoesNotAccrue() {
    var l = Ledger(); let due = l.run(120, present: false)
    #expect(due == 0); #expect(l.owed == 0)
}

@Test func absencePausesWithoutResetting() {
    var l = Ledger(); l.run(50); l.run(20, present: false); #expect(l.owed == 0)
    l.run(10); #expect(l.owed == 10)
}

@Test func skippedSetCarriesOver() {                 // the spec's 10:00 → 11:00 example
    var l = Ledger()
    l.run(60); #expect(l.owed == 10)
    l.run(60); #expect(l.owed == 20); #expect(l.target(perSet: 10) == 20)
    l.squats(12); l.sessionEnded(reachedTarget: false)
    #expect(l.owed == 8); #expect(l.doneToday == 12)
    l.run(60); #expect(l.owed == 18)
}

@Test func carryOverIsCapped() {
    var l = Ledger(); let due = l.run(240)
    #expect(due == 4); #expect(l.owed == 30)
}

@Test func clearingTheDebtRestartsTheCountdown() {
    var l = Ledger(); l.run(60); l.run(20)           // owed 10, ten minutes into the next interval
    l.squats(10); l.sessionEnded(reachedTarget: true)
    #expect(l.owed == 0); #expect(l.elapsed == 0)
}

@Test func partialSetKeepsTheCountdownRunning() {
    var l = Ledger(); l.run(60); l.run(20)
    l.squats(6); l.sessionEnded(reachedTarget: false)
    #expect(l.owed == 4); #expect(l.elapsed == 600)
}

@Test func voluntarySetCountsAndRestartsTheCountdown() {
    var l = Ledger(); l.run(20); #expect(l.target(perSet: 10) == 10)
    l.squats(10); l.sessionEnded(reachedTarget: true)
    #expect(l.owed == 0); #expect(l.doneToday == 10); #expect(l.elapsed == 0)
}

@Test func newDayClearsEverything() {
    var l = Ledger(); l.run(120); l.squats(1)
    l.run(1, today: "2026-11-24")
    #expect(l.owed == 0); #expect(l.doneToday == 0); #expect(l.elapsed == 30)
}

@Test func oneTickNeverAccruesMoreThanOneSet() {     // interval shortened mid-run, or a late timer
    var l = Ledger(); l.run(40)
    let due = l.run(1, minutes: 5)
    #expect(due == 1); #expect(l.owed == 10); #expect(l.elapsed == 0)
    var late = Ledger()
    let lateDue = late.tick(seconds: 7200, present: true, today: "2026-11-23", perSet: 10, interval: 1800, maxOwed: 30)
    #expect(lateDue); #expect(late.owed == 10)
}

@Test func loweredCapClampsOwed() {
    var l = Ledger(); l.run(180); #expect(l.owed == 30)
    l.run(60, maxOwed: 15); #expect(l.owed == 15)
}

@Test func noticeTextMatchesTheSpec() {
    var l = Ledger(); l.run(60); #expect(l.noticeText(perSet: 10) == "Time for 10 squats")
    l.run(60); #expect(l.noticeText(perSet: 10) == "20 squats — 10 carried over")
}

// NoticeGate: when a due set may be announced.
@Test func noticePostsOnceWhenDue() {
    var g = NoticeGate()
    let first = g.shouldPost(due: true, hold: false, drop: false)
    let second = g.shouldPost(due: false, hold: false, drop: false)
    #expect(first); #expect(!second)
}

@Test func noticeIsHeldDuringACallAndSentWhenItEnds() {
    var g = NoticeGate()
    let duringCall = g.shouldPost(due: true, hold: true, drop: false)
    let stillInCall = g.shouldPost(due: false, hold: true, drop: false)
    let callEnded = g.shouldPost(due: false, hold: false, drop: false)
    let after = g.shouldPost(due: false, hold: false, drop: false)
    #expect(!duringCall); #expect(!stillInCall); #expect(callEnded); #expect(!after)
}

@Test func noticeIsDroppedWhileASetIsInProgress() {
    var g = NoticeGate()
    let duringSet = g.shouldPost(due: true, hold: false, drop: true)
    let afterSet = g.shouldPost(due: false, hold: false, drop: false)
    #expect(!duringSet); #expect(!afterSet)
}

// Texts and countdown shown in the menu.
@Test func menuTextsFollowWhatIsOwed() {
    var l = Ledger()
    #expect(l.statusText == "All caught up"); #expect(l.actionText(perSet: 10) == "Do a set of 10")
    l.run(60)
    #expect(l.statusText == "10 squats owed"); #expect(l.actionText(perSet: 10) == "Do 10 squats")
    l.squats(9)
    #expect(l.statusText == "1 squat owed"); #expect(l.actionText(perSet: 10) == "Do 1 squat")
}

@Test func countdownProgressRunsFromZeroToOne() {
    var l = Ledger(); #expect(l.progress(interval: 1800) == 0)
    l.run(30); #expect(l.progress(interval: 1800) == 0.5)
    l.elapsed = 5000; #expect(l.progress(interval: 1800) == 1)        // interval shortened mid-run
    #expect(l.progress(interval: 0) == 0)
}

// MARK: The week

@Test func aNewDayFilesTheOldOneInTheHistory() {
    var l = Ledger(); l.run(1, today: "2026-11-23"); l.squats(12)
    #expect(l.done(on: "2026-11-23") == 12)
    l.run(1, today: "2026-11-24"); l.squats(5)
    #expect(l.done(on: "2026-11-23") == 12); #expect(l.done(on: "2026-11-24") == 5)
    #expect(l.done(on: "2026-11-22") == 0)
}

@Test func historyKeepsOnlyTheLastWeek() {
    var l = Ledger()
    for day in 10...20 { l.run(1, today: "2026-11-\(day)"); l.squats(day) }
    #expect(l.done(on: "2026-11-20") == 20); #expect(l.done(on: "2026-11-14") == 14)
    #expect(l.done(on: "2026-11-13") == 0); #expect(l.history.count == 6)
}

@Test func aLedgerSavedBeforeTheHistoryExistedStillLoads() throws {
    let saved = Data(#"{"owed":7,"doneToday":13,"elapsed":90,"day":"2026-11-26"}"#.utf8)
    let l = try JSONDecoder().decode(Ledger.self, from: saved)
    #expect(l.owed == 7); #expect(l.doneToday == 13); #expect(l.history.isEmpty)
    #expect(try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(l)) == l)
}

@Test func aDayThatComesRoundAgainKeepsItsSquats() {             // time zone moved west across midnight
    var l = Ledger(); l.run(1, today: "2026-11-26"); l.squats(10)
    l.run(1, today: "2026-11-25"); #expect(l.done(on: "2026-11-26") == 10)
    l.run(1, today: "2026-11-26"); l.squats(4); #expect(l.done(on: "2026-11-26") == 14)
    l.run(1, today: "2026-11-27"); #expect(l.done(on: "2026-11-26") == 14)
}
