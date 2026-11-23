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
        // ponytail: thresholds measured from one clip of one person (ten squats at 1.5 m, peak
        // drops 1.29–1.48 shoulder widths, standing sway up to 0.09). down = 0.6 × smallest peak,
        // up = 0.3 × down. If it miscounts for another body or desk, record again and retune;
        // `down` is also the user's "Squat depth" slider.
        public var down = 0.77, up = 0.23, minRepDuration = 0.5, minConfidence = 0.3
        public var stillSeconds = 1.0, stillTolerance = 0.15, lostSeconds = 3.0
        public var smoothing = 3
        /// While counting, shoulders this much narrower or wider than the baseline are not the
        /// person we calibrated on at that spot (measured range during real squats: 0.90–1.22).
        public var widthRange = 0.6...1.6
        public init() {}
    }

    public enum Phase { case searching, calibrating, counting }

    public private(set) var phase = Phase.searching
    /// Last smoothed drop, in shoulder widths.
    public private(set) var drop = 0.0
    public var count: Int { reps.count }
    /// Seconds since a person was last tracked (or since the first frame, if nobody has been).
    public private(set) var unseenFor: TimeInterval = 0

    private let tuning: Tuning
    private var reps: RepCounter
    private var window: [PoseSample] = []
    private var baselineY = 0.0, baselineWidth = 1.0
    private var lastSeen: TimeInterval?
    private var firstFrameAt: TimeInterval?

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
        reps = RepCounter(down: tuning.down, up: tuning.up, minDuration: tuning.minRepDuration)
    }

    /// True when this frame completes a rep.
    public mutating func add(_ frame: PoseFrame) -> Bool {
        if firstFrameAt == nil { firstFrameAt = frame.time }
        guard let sample = usableSample(from: frame) else {
            unseenFor = frame.time - (lastSeen ?? firstFrameAt ?? frame.time)
            if phase != .searching, unseenFor > tuning.lostSeconds {
                phase = .searching
                window = []
                drop = 0
                reps.abandonRep()   // a squat they walked out of must not complete on return
            }
            return false
        }
        lastSeen = sample.time
        unseenFor = 0
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

private extension SquatTracker {
    /// The frame's shoulder sample, unless it cannot be compared with the baseline: while counting,
    /// much narrower shoulders are someone in the background and much wider or narrower ones are
    /// the same person at another distance (for example a baseline taken at the desk before
    /// walking back). Rejected long enough, the tracker re-calibrates where the person now stands.
    func usableSample(from frame: PoseFrame) -> PoseSample? {
        guard let sample = frame.sample(minConfidence: tuning.minConfidence) else { return nil }
        if phase == .counting, !tuning.widthRange.contains(sample.width / baselineWidth) { return nil }
        return sample
    }
}

private func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

private func spread(_ samples: [PoseSample]) -> Double {
    let ys = samples.map(\.y)
    return (ys.max() ?? 0) - (ys.min() ?? 0)
}
