import Foundation

/// Counts a rep when `drop` rises to `down` and then returns to `up`: once, on the way back up.
public struct RepCounter {
    private let down, up: Double
    private let minDuration: TimeInterval
    public private(set) var count = 0
    private var startedAt: TimeInterval?   // when `drop` first rose above `up`
    private var armed = false              // `drop` has reached `down` since then

    public init(down: Double, up: Double, minDuration: TimeInterval) {
        self.down = down; self.up = up; self.minDuration = minDuration
    }

    /// True when this sample completes a rep.
    public mutating func add(drop: Double, at time: TimeInterval) -> Bool {
        if drop > up {
            if startedAt == nil { startedAt = time }
            if drop >= down { armed = true }
            return false
        }
        defer { abandonRep() }
        guard armed, let startedAt, time - startedAt >= minDuration else { return false }
        count += 1
        return true
    }

    /// Forget a rep in progress (the person left the frame); the count is kept.
    public mutating func abandonRep() {
        startedAt = nil
        armed = false
    }
}

/// Turns pose frames into counted squats: waits for the person to stand still, records that as the
/// baseline, then measures how far the shoulders drop from it in units of shoulder width.
public struct SquatTracker {
    public struct Tuning {
        // ponytail: fixed thresholds from one person's recordings. If it miscounts for another
        // body or desk, re-record with the spike and retune; `down` is also the user's depth slider.
        public var down = 0.7, up = 0.2, minRepDuration = 0.5, minConfidence = 0.3
        public var stillSeconds = 1.0, stillTolerance = 0.1, lostSeconds = 3.0
        public var smoothing = 3
        public init() {}
    }

    public enum Phase { case searching, calibrating, counting }

    public private(set) var phase = Phase.searching
    /// Last smoothed drop, in shoulder widths.
    public private(set) var drop = 0.0
    public var count: Int { reps.count }

    private let tuning: Tuning
    private var reps: RepCounter
    private var window: [PoseSample] = []
    private var baselineY = 0.0, baselineWidth = 1.0
    private var lastSeen: TimeInterval?

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
        reps = RepCounter(down: tuning.down, up: tuning.up, minDuration: tuning.minRepDuration)
    }

    /// True when this frame completes a rep.
    public mutating func add(_ frame: PoseFrame) -> Bool {
        guard let sample = frame.sample(minConfidence: tuning.minConfidence) else {
            if phase != .searching, let lastSeen, frame.time - lastSeen > tuning.lostSeconds {
                phase = .searching
                window = []
                drop = 0
                reps.abandonRep()   // a squat they walked out of must not complete on return
            }
            return false
        }
        lastSeen = sample.time
        window.append(sample)

        switch phase {
        case .searching:
            phase = .calibrating
            return false
        case .calibrating:
            while spread(window) > tuning.stillTolerance * mean(window.map(\.width)) { window.removeFirst() }
            guard sample.time - window[0].time >= tuning.stillSeconds else { return false }
            baselineY = mean(window.map(\.y))
            baselineWidth = mean(window.map(\.width))
            phase = .counting
            return false
        case .counting:
            window = Array(window.suffix(tuning.smoothing))
            drop = (baselineY - mean(window.map(\.y))) / baselineWidth
            return reps.add(drop: drop, at: sample.time)
        }
    }
}

private func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

private func spread(_ samples: [PoseSample]) -> Double {
    let ys = samples.map(\.y)
    return (ys.max() ?? 0) - (ys.min() ?? 0)
}
