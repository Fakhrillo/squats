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
    let first = g.shouldPost(due: true, inCall: false, sessionOpen: false)
    let second = g.shouldPost(due: false, inCall: false, sessionOpen: false)
    #expect(first); #expect(!second)
}

@Test func noticeIsHeldDuringACallAndSentWhenItEnds() {
    var g = NoticeGate()
    let duringCall = g.shouldPost(due: true, inCall: true, sessionOpen: false)
    let stillInCall = g.shouldPost(due: false, inCall: true, sessionOpen: false)
    let callEnded = g.shouldPost(due: false, inCall: false, sessionOpen: false)
    let after = g.shouldPost(due: false, inCall: false, sessionOpen: false)
    #expect(!duringCall); #expect(!stillInCall); #expect(callEnded); #expect(!after)
}

@Test func noticeIsDroppedWhileASetIsInProgress() {
    var g = NoticeGate()
    let duringSet = g.shouldPost(due: true, inCall: false, sessionOpen: true)
    let afterSet = g.shouldPost(due: false, inCall: false, sessionOpen: false)
    #expect(!duringSet); #expect(!afterSet)
}
