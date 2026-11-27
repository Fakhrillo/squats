import Foundation
import Testing
@testable import SquatsKit

// MARK: RepCounter

private func counted(_ drops: [Double], dt: Double = 0.2) -> (count: Int, hits: [Bool]) {
    var c = RepCounter(down: 0.7, up: 0.2, minDuration: 0.5)
    let hits = drops.enumerated().map { c.add(drop: $1, at: Double($0) * dt) }
    return (c.count, hits)
}

@Test func fullCycleCountsOnceOnTheWayUp() {
    let r = counted([0, 0.4, 0.8, 0.8, 0.4, 0.1])
    #expect(r.hits == [false, false, false, false, false, true]); #expect(r.count == 1)
}

@Test func shallowDipDoesNotCount() { #expect(counted([0, 0.4, 0.6, 0.4, 0.1]).count == 0) }

@Test func wobbleAtTheBottomCountsOnce() { #expect(counted([0, 0.8, 0.65, 0.8, 0.65, 0.8, 0.1]).count == 1) }

@Test func glitchShorterThanHalfASecondIsIgnored() { #expect(counted([0, 0.9, 0], dt: 0.05).count == 0) }

@Test func neverComingBackUpCountsNothing() { #expect(counted([0, 0.5, 0.9, 0.9, 0.9]).count == 0) }

@Test func aDipThatComesUpShortIsReportedAsShallow() {
    var c = RepCounter(down: 0.7, up: 0.2, minDuration: 0.5)
    for (i, d) in [0, 0.4, 0.6, 0.4, 0.1].enumerated() { _ = c.add(drop: d, at: Double(i) * 0.2) }
    #expect(c.shallow == 1); #expect(c.count == 0)
    for (i, d) in [0, 0.25, 0.3, 0.25, 0.1].enumerated() { _ = c.add(drop: d, at: 2 + Double(i) * 0.2) }
    #expect(c.shallow == 1)                                           // sway is not a shallow squat
}

@Test func fiveSquatsCountFive() {
    #expect(counted(Array(repeating: [0.1, 0.5, 0.9, 0.5, 0.1], count: 5).flatMap { $0 }).count == 5)
}

// MARK: SquatTracker on synthetic motion

/// The spec's starting values, pinned so re-tuning the defaults cannot break the synthetic tests.
private var specTuning: SquatTracker.Tuning {
    var t = SquatTracker.Tuning(); t.down = 0.7; t.up = 0.2; t.stillTolerance = 0.1; return t
}

/// Feeds synthetic 15 fps frames with level shoulders `width` apart at height `y`.
private struct Sim {
    var tracker = SquatTracker(tuning: specTuning), t = 0.0
    mutating func feed(_ ys: [Double?], width: Double = 0.25, confidence: Double = 0.9) {
        for y in ys {
            var f = PoseFrame(time: t)
            if let y {
                f.leftShoulder = Joint(x: 0.9 - width / 2, y: y, confidence: confidence)
                f.rightShoulder = Joint(x: 0.9 + width / 2, y: y, confidence: confidence)
            }
            _ = tracker.add(f); t += 1.0 / 15
        }
    }
}

private func still(_ y: Double, _ seconds: Double) -> [Double?] { Array(repeating: y, count: Int(seconds * 15)) }

private func squat(from y: Double, depth: Double) -> [Double?] {      // 1.2 s down and up
    (0..<18).map { y - depth * sin(Double($0) / 17 * .pi) }
}

@Test func calibratesAfterOneStillSecond() {
    var s = Sim(); s.feed(still(0.6, 0.5)); #expect(s.tracker.phase == .calibrating)
    s.feed(still(0.6, 0.7)); #expect(s.tracker.phase == .counting)
}

@Test func movementDelaysCalibration() {
    var s = Sim(); s.feed((0..<15).map { 0.5 + Double($0) * 0.007 }); #expect(s.tracker.phase == .calibrating)
    s.feed(still(0.6, 1.2)); #expect(s.tracker.phase == .counting); #expect(abs(s.tracker.drop) < 0.05)
}

@Test func countsThreeSquats() {
    var s = Sim(); s.feed(still(0.6, 1.2))
    for _ in 0..<3 { s.feed(squat(from: 0.6, depth: 0.25)); s.feed(still(0.6, 0.3)) }
    #expect(s.tracker.count == 3)
}

@Test func depthIsMeasuredInShoulderWidths() {       // same dip, person half as far away: only 0.66 of a width
    var s = Sim(); s.feed(still(0.7, 1.2), width: 0.38); #expect(s.tracker.phase == .counting)
    s.feed(squat(from: 0.7, depth: 0.25), width: 0.38)
    s.feed(still(0.7, 0.3), width: 0.38); #expect(s.tracker.count == 0)
}

@Test func lowConfidenceFramesAreIgnored() {
    var s = Sim(); s.feed(still(0.6, 1.2))
    for y in squat(from: 0.6, depth: 0.25) { s.feed([y]); s.feed([0.0], confidence: 0.1) }
    s.feed(still(0.6, 0.3)); #expect(s.tracker.count == 1)
}

@Test func leavingTheFrameRebaselinesAndKeepsTheCount() {
    var s = Sim(); s.feed(still(0.6, 1.2)); s.feed(squat(from: 0.6, depth: 0.25)); s.feed(still(0.6, 0.3))
    s.feed(Array(repeating: nil, count: 53))                          // 3.5 s with nobody in view
    #expect(s.tracker.phase == .searching); #expect(s.tracker.count == 1)
    s.feed(still(0.5, 1.2)); s.feed(squat(from: 0.5, depth: 0.25)); s.feed(still(0.5, 0.3))
    #expect(s.tracker.count == 2)
}

@Test func leavingTheFrameMidSquatCountsNoPhantomRep() {
    var s = Sim(); s.feed(still(0.6, 1.2))
    s.feed(Array(squat(from: 0.6, depth: 0.25).prefix(9)))            // down to the bottom, then gone
    s.feed(Array(repeating: nil, count: 53))
    s.feed(still(0.6, 2.0))                                            // back, standing: nothing was completed
    #expect(s.tracker.phase == .counting); #expect(s.tracker.count == 0)
}

// MARK: SquatTracker on recorded squats (joint coordinates logged by the recorder spike)

private func count(fixture name: String) throws -> Int {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"))
    var tracker = SquatTracker()
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        if let f = PoseFrame(csvLine: String(line)) { _ = tracker.add(f) }
    }
    return tracker.count
}

/// 25 s at 1.5 m from the laptop: two seconds standing, then ten squats (the clip holds ten, not five).
@Test func recordedSquatsAtOneAndAHalfMetresCountTen() throws {
    let n = try count(fixture: "squats-1.5m")
    #expect(n == 10)
}

// MARK: Review fixes

@Test func nothingIsReadAtTheDeskAndCountingStartsAtTheSquatSpot() {
    // Press Start at the laptop: close to the camera, shoulders wide and low in the frame.
    var s = Sim(); s.feed(still(0.3, 2.0), width: 0.8)
    #expect(s.tracker.phase == .calibrating)
    if case .tooClose(let steps)? = s.tracker.framing { #expect(steps > 1) } else { Issue.record("expected too close") }
    // Walk back to the squat spot and stand still for a second: now it starts.
    s.feed(still(0.7, 1.2), width: 0.33)
    #expect(s.tracker.phase == .counting); #expect(s.tracker.framing == .good)
    for _ in 0..<3 { s.feed(squat(from: 0.7, depth: 0.33), width: 0.33); s.feed(still(0.7, 0.3), width: 0.33) }
    #expect(s.tracker.count == 3)
}

@Test func aSmallerPersonInTheBackgroundIsIgnored() {
    var s = Sim(); s.feed(still(0.6, 1.2))
    // The user is missed for a second and a colleague far behind is reported instead:
    // narrow shoulders, lower in the frame, which would read as a deep "drop".
    s.feed(still(0.4, 1.0), width: 0.1)
    s.feed(still(0.6, 1.0))
    #expect(s.tracker.count == 0)
}

// MARK: Distance and readiness

@Test func framingJudgesDistanceFromShoulderWidth() {
    let t = SquatTracker.Tuning()
    #expect(t.framing(y: 0.713, width: 0.325) == .good)               // the recorded clip, 1.5 m
    // 0.8 m away: about 1.43 m is the aim, so one step back.
    if case .tooClose(let steps) = t.framing(y: 0.8, width: 0.61) { #expect(abs(steps - 1.06) < 0.05) }
    else { Issue.record("expected too close") }
    if case .tooFar(let steps) = t.framing(y: 0.5, width: 0.1) { #expect(steps > 3) }
    else { Issue.record("expected too far") }
    // Right size, but no room below the shoulders for a squat: a little further back.
    #expect(t.framing(y: 0.3, width: 0.3) == .tooClose(steps: 0.5))
    // 1.1 m in a small room: closer than ideal, but the whole squat still fits in the picture.
    #expect(t.framing(y: 0.8, width: 0.44) == .good)
    #expect(t.framing(y: 0.5, width: 0) == .tooFar(steps: 9))         // never an endless step count
}

@Test func swayAtTheEdgeOfTheGoodRangeStillStarts() {
    var s = Sim()
    for i in 0..<45 { s.feed([0.75], width: i % 2 == 0 ? 0.452 : 0.468) }   // either side of the limit
    #expect(s.tracker.phase == .counting)
}

@Test func readinessFillsWhileStandingStillAndDeepEnoughIsReported() {
    var s = Sim(); s.feed(still(0.6, 0.5))
    #expect(s.tracker.stillProgress > 0.3); #expect(s.tracker.stillProgress < 0.7)
    s.feed(still(0.6, 0.7)); #expect(s.tracker.phase == .counting)
    s.feed(Array(squat(from: 0.6, depth: 0.25).prefix(9))); #expect(s.tracker.isDeepEnough)
    s.feed(Array(squat(from: 0.6, depth: 0.25).suffix(9))); s.feed(still(0.6, 0.3))
    #expect(!s.tracker.isDeepEnough); #expect(s.tracker.count == 1)
}

// MARK: Stuck count (a standing level read at the wrong moment must correct itself)

@Test func aStandingLevelTakenAtTheBottomOfASquatCorrectsItself() {
    // Moving before the app was ready: it catches a one-second pause partway down.
    var s = Sim(); s.feed(still(0.35, 1.2)); #expect(s.tracker.phase == .counting)
    s.feed(still(0.6, 0.3))
    for _ in 0..<3 { s.feed(squat(from: 0.6, depth: 0.25)); s.feed(still(0.6, 0.3)) }
    #expect(s.tracker.count == 3)
}

@Test func aStandingLevelThatWasTooHighCorrectsItself() {
    var s = Sim(); s.feed(still(0.6, 1.2))
    // Settling into a lower stance, 0.32 shoulder widths under the first reading: every squat
    // from here used to stay unfinished, because the top never read as "standing".
    s.feed(still(0.52, 6.5))
    for _ in 0..<3 { s.feed(squat(from: 0.52, depth: 0.25)); s.feed(still(0.52, 0.3)) }
    #expect(s.tracker.count == 3)
}

@Test func sittingDownForLongerThanASlowSquatIsNotASquat() {
    var s = Sim(); s.feed(still(0.6, 1.2))
    s.feed(still(0.3, 8)); s.feed(still(0.6, 1))
    #expect(s.tracker.count == 0)
}

@Test func oneBadPoseFrameDoesNotStopTheCount() {
    var s = Sim(); s.feed(still(0.6, 3))
    s.feed([0.85])                                                    // a single pose far above the shoulders
    for _ in 0..<5 { s.feed(squat(from: 0.6, depth: 0.25)); s.feed(still(0.6, 0.3)) }
    #expect(s.tracker.count == 5)
}

@Test func aMomentOnTiptoeDoesNotStopTheCount() {
    var s = Sim(); s.feed(still(0.6, 5))
    s.feed(still(0.68, 0.5))                                          // a third of a width up for half a second
    for _ in 0..<5 { s.feed(squat(from: 0.6, depth: 0.25)); s.feed(still(0.6, 0.3)) }
    #expect(s.tracker.count == 5)
}

@Test func reportsHowLongNobodyHasBeenTracked() {
    var s = Sim(); s.feed(Array(repeating: nil, count: 15 * 61))      // window open, nobody in view
    #expect(s.tracker.unseenFor >= 60)
    s.feed(still(0.6, 0.2)); #expect(s.tracker.unseenFor == 0)
    s.feed(Array(repeating: nil, count: 15 * 10)); #expect(s.tracker.unseenFor >= 9.9)
}

// MARK: Abandoned sets and calibration

@Test func someoneInViewWhoNeverSquatsIsIdle() {                  // sat back down with the window open
    var s = Sim(); s.feed(still(0.6, 72)); #expect(s.tracker.unseenFor == 0); #expect(s.tracker.idleFor >= 69)
}

@Test func aCountedSquatRestartsTheIdleClock() {
    var s = Sim(); s.feed(still(0.6, 22)); #expect(s.tracker.idleFor >= 19)
    s.feed(squat(from: 0.6, depth: 0.25)); s.feed(still(0.6, 2))
    #expect(s.tracker.count == 1); #expect(s.tracker.idleFor < 3)
}

@Test func theDepthOfEachCountedSquatIsReported() {
    var s = Sim(); s.feed(still(0.6, 1.2)); #expect(s.tracker.lastRepDepth == 0)
    s.feed(squat(from: 0.6, depth: 0.25)); s.feed(still(0.6, 0.3))
    #expect(abs(s.tracker.lastRepDepth - 1.0) < 0.1)             // 0.25 down with shoulders 0.25 wide
    s.feed(squat(from: 0.6, depth: 0.30)); s.feed(still(0.6, 0.3))
    #expect(abs(s.tracker.lastRepDepth - 1.2) < 0.1)
}

@Test func depthIsSetFromTheShallowestOfYourOwnSquats() {
    typealias Tuning = SquatTracker.Tuning
    #expect(Tuning.depth(fromSquats: []) == nil)
    #expect(abs(Tuning.depth(fromSquats: [1.48, 1.29, 1.40])! - 0.774) < 0.001)   // the recorded clip: 0.77
    #expect(Tuning.depth(fromSquats: [0.2, 0.9]) == Tuning.depthRange.lowerBound)
    #expect(Tuning.depth(fromSquats: [3, 4]) == Tuning.depthRange.upperBound)
    // Any squat the calibration run can see gives a depth the slider can show.
    #expect(Tuning.depth(fromSquats: [Tuning.calibrationDown]) == Tuning.depthRange.lowerBound)
}

@Test func squatsThatComeUpShortAreStillActivity() {             // trying, and being told "go deeper"
    var s = Sim(); s.feed(still(0.6, 1.2))
    for _ in 0..<40 { s.feed(squat(from: 0.6, depth: 0.14)); s.feed(still(0.6, 0.4)) }
    #expect(s.tracker.count == 0); #expect(s.tracker.shallowDips > 30); #expect(s.tracker.idleFor < 3)
}

@Test func gettingIntoPositionRestartsTheIdleClock() {
    var s = Sim(); s.feed(Array(repeating: nil, count: 15 * 40)); #expect(s.tracker.idleFor >= 39)
    s.feed(still(0.6, 1.3)); #expect(s.tracker.phase == .counting); #expect(s.tracker.idleFor < 1)
}

@Test func calibratingNeedsRoomForTheWholeSquat() {
    typealias Tuning = SquatTracker.Tuning
    var t = Tuning(); t.down = Tuning.calibrationDown; t.roomBelow = Tuning.calibrationRoom
    // Shoulders 0.96 widths above the bottom edge: a 1.3-wide squat would leave the picture.
    #expect(t.framing(y: 0.24, width: 0.25) == .tooClose(steps: 0.5))
    #expect(t.framing(y: 0.50, width: 0.25) == .good)
    #expect(t.framing(y: 0.733, width: 0.292) == .good)          // where the recorded clip stood
}
