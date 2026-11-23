import Testing
@testable import SquatsKit

private func shoulders(_ l: (Double, Double), _ r: (Double, Double), c: Double = 0.9) -> PoseFrame {
    var f = PoseFrame(time: 1.5)
    f.leftShoulder = Joint(x: l.0, y: l.1, confidence: c)
    f.rightShoulder = Joint(x: r.0, y: r.1, confidence: c)
    return f
}

@Test func csvRoundTrip() {
    var f = shoulders((0.8, 0.62), (1.1, 0.58))
    f.nose = Joint(x: 0.95, y: 0.8, confidence: 0.7)
    #expect(PoseFrame(csvLine: f.csvLine) == f)
    #expect(PoseFrame.csvHeader.split(separator: ",").count == 19)
    #expect(PoseFrame(csvLine: PoseFrame.csvHeader) == nil)
}

@Test func sampleIsShoulderMidpointAndDistance() throws {
    let s = try #require(shoulders((0.8, 0.62), (1.1, 0.58)).sample(minConfidence: 0.3))
    #expect(abs(s.y - 0.6) < 1e-9)
    #expect(abs(s.width - 0.30265) < 1e-4)
    #expect(s.time == 1.5)
}

@Test func noSampleWhenAShoulderIsMissingOrUnsure() {
    #expect(shoulders((0.8, 0.6), (1.1, 0.6), c: 0.2).sample(minConfidence: 0.3) == nil)
    var f = shoulders((0.8, 0.6), (1.1, 0.6)); f.rightShoulder = nil
    #expect(f.sample(minConfidence: 0.3) == nil)
}

@Test func nearestPicksWidestShoulders() {
    let far = shoulders((0.85, 0.6), (0.95, 0.6)), near = shoulders((0.8, 0.6), (1.1, 0.6))
    #expect(PoseFrame.nearest([far, PoseFrame(time: 0), near]) == near)
    #expect(PoseFrame.nearest([]) == nil)
    // Nobody has shoulders in view: still report the first person, so head joints are not lost.
    #expect(PoseFrame.nearest([PoseFrame(time: 2)]) == PoseFrame(time: 2))
}
