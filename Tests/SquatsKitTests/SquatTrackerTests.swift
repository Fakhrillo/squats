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

@Test func depthIsMeasuredInShoulderWidths() {       // same dip, person twice as close: only half a width
    var s = Sim(); s.feed(still(0.6, 1.2), width: 0.5); s.feed(squat(from: 0.6, depth: 0.25), width: 0.5)
    s.feed(still(0.6, 0.3), width: 0.5); #expect(s.tracker.count == 0)
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

@Test func baselineTakenAtTheDeskIsReplacedAfterWalkingBack() {
    // Press Start at the laptop: close to the camera, shoulders wide and low in the frame.
    var s = Sim(); s.feed(still(0.3, 1.2), width: 0.8); #expect(s.tracker.phase == .counting)
    // Walk back to the squat spot: the same person is now far narrower than the desk baseline.
    s.feed(still(0.7, 4.5), width: 0.33)
    #expect(s.tracker.phase == .counting)                             // re-calibrated at the new spot
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

@Test func reportsHowLongNobodyHasBeenTracked() {
    var s = Sim(); s.feed(Array(repeating: nil, count: 15 * 61))      // window open, nobody in view
    #expect(s.tracker.unseenFor >= 60)
    s.feed(still(0.6, 0.2)); #expect(s.tracker.unseenFor == 0)
    s.feed(Array(repeating: nil, count: 15 * 10)); #expect(s.tracker.unseenFor >= 9.9)
}
