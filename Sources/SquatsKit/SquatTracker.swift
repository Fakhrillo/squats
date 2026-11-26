import Foundation

/// Counts a rep when `drop` rises to `down` and then returns to `up`: once, on the way back up.
public struct RepCounter {
    private let down, up: Double
    private let minDuration: TimeInterval
    public private(set) var count = 0
    /// Dips that came back up well short of `down`: the cue for "go a little deeper".
    public private(set) var shallow = 0
    /// `drop` has reached `down` in the rep in progress: it will count on the way up.
    public private(set) var armed = false
    private var startedAt: TimeInterval?   // when `drop` first rose above `up`
    private var peak = 0.0

    public init(down: Double, up: Double, minDuration: TimeInterval) {
        self.down = down; self.up = up; self.minDuration = minDuration
    }

    /// True when this sample completes a rep.
    public mutating func add(drop: Double, at time: TimeInterval) -> Bool {
        if drop > up {
            if startedAt == nil { startedAt = time }
            peak = max(peak, drop)
            if drop >= down { armed = true }
            return false
        }
        defer { abandonRep() }
        guard let startedAt, time - startedAt >= minDuration else { return false }
        guard armed else {
            if peak >= down * 0.6 { shallow += 1 }   // more than sway, less than a squat
            return false
        }
        count += 1
        return true
    }

    /// Forget a rep in progress (the person left the frame); the count is kept.
    public mutating func abandonRep() {
        startedAt = nil
        armed = false
        peak = 0
    }
}

/// Where the person stands compared with a good squat spot.
public enum Framing: Equatable {
    case good
    /// With roughly how many steps back are needed.
    case tooClose(steps: Double)
    /// With roughly how many steps forward are needed.
    case tooFar(steps: Double)
}

/// Turns pose frames into counted squats: waits for the person to stand still at a good distance,
/// then measures how far the shoulders drop below their recent high point, in shoulder widths.
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
        /// "Standing" is the highest the shoulders have been in this many seconds: longer than a
        /// slow squat, short enough that a bad first reading is gone after a couple of reps.
        public var highSeconds = 6.0
        // ponytail: "highest" means the height the shoulders reached or passed in this share of
        // those readings, so a bad pose frame or a moment on tiptoe is not taken for standing.
        // Anything higher for longer (about 0.7 s) still is, and costs the reps until it ages out.
        public var highShare = 0.12

        // ponytail: distance is judged from shoulder width alone, scaled from the same clip
        // (shoulders 0.325 of the image height at 1.5 m on a MacBook camera). Another camera or
        // build shifts the guidance by a step or so; re-measure `widthAtOneMetre` if it is off.
        public var widthAtOneMetre = 0.4875
        /// Shoulder widths, in image heights, that are a workable distance: about 1.1 m to 3.2 m.
        public var goodWidth = 0.15...0.46
        /// Where "step back" sends you: about 1.4 m, comfortably inside the range.
        public var aimWidth = 0.34
        public var stepMetres = 0.6
        public init() {}

        /// Judges a standing position: shoulder midpoint height `y` and shoulder `width`, both in
        /// image heights. `lenient` widens every limit a little: once someone is at a good spot,
        /// ordinary sway must not send them away again.
        public func framing(y: Double, width: Double, lenient: Bool = false) -> Framing {
            let slack = lenient ? 0.08 : 0
            func steps(to target: Double) -> Double {
                width > 0 ? min(9, abs(widthAtOneMetre / target - widthAtOneMetre / width) / stepMetres) : 9
            }
            if width > goodWidth.upperBound * (1 + slack) { return .tooClose(steps: steps(to: aimWidth)) }
            if width < goodWidth.lowerBound * (1 - slack) { return .tooFar(steps: steps(to: goodWidth.lowerBound * 1.2)) }
            // Right size, but the shoulders would leave the picture before the squat is deep
            // enough, or they sit at its top edge. A little further back fixes both.
            if y / width < down + 0.4 - 2 * slack || y > 0.92 + slack / 2 { return .tooClose(steps: 0.5) }
            return .good
        }
    }

    public enum Phase { case searching, calibrating, counting }

    public private(set) var phase = Phase.searching
    /// Last smoothed drop below the standing level, in shoulder widths.
    public private(set) var drop = 0.0
    public var count: Int { reps.count }
    /// The squat in progress is deep enough to count.
    public var isDeepEnough: Bool { reps.armed }
    /// Dips that came up short so far.
    public var shallowDips: Int { reps.shallow }
    /// Seconds since a person was last tracked (or since the first frame, if nobody has been).
    public private(set) var unseenFor: TimeInterval = 0
    /// Where the tracked person stands; nil while nobody is tracked.
    public private(set) var framing: Framing?
    /// How much of the stand-still second before counting has passed, 0…1.
    public private(set) var stillProgress = 0.0

    private let tuning: Tuning
    private var reps: RepCounter
    private var window: [PoseSample] = []   // calibrating: the still stretch so far; counting: the last few
    private var highs: [(time: TimeInterval, y: Double)] = []
    private var standingY = 0.0, baselineWidth = 1.0
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
                highs = []
                drop = 0
                stillProgress = 0
                framing = nil
                reps.abandonRep()   // a squat they walked out of must not complete on return
            }
            return false
        }
        lastSeen = sample.time
        unseenFor = 0
        framing = tuning.framing(y: sample.y, width: sample.width, lenient: framing == .good)
        window.append(sample)

        switch phase {
        case .searching:
            phase = .calibrating
            return false
        case .calibrating:
            // No reading at the desk or across the room: it would be useless at the squat spot.
            guard framing == .good else {
                window = []
                stillProgress = 0
                return false
            }
            while spread(window) > tuning.stillTolerance * mean(window.map(\.width)) { window.removeFirst() }
            let stillFor = sample.time - window[0].time
            stillProgress = min(1, stillFor / tuning.stillSeconds)
            guard stillFor >= tuning.stillSeconds else { return false }
            standingY = mean(window.map(\.y))
            baselineWidth = mean(window.map(\.width))
            highs = window.map { ($0.time, $0.y) }   // the still second is the first evidence of "standing"
            phase = .counting
            return false
        case .counting:
            window = Array(window.suffix(tuning.smoothing))
            let y = mean(window.map(\.y))
            // The standing level follows the person: it is their highest point lately. A first
            // reading taken at a bad moment (mid-squat, slouching, a step closer) used to stay
            // for the whole set and nothing counted until they left the frame.
            highs.append((sample.time, y))
            highs.removeAll { $0.time < sample.time - tuning.highSeconds }
            let ranked = highs.map(\.y).sorted(by: >)
            let rank = max(4, Int((Double(ranked.count) * tuning.highShare).rounded(.up)))
            let high = ranked[min(rank, ranked.count) - 1]
            // If the level itself comes down, they did not stand back up (sat down, walked off):
            // whatever was in progress was not a squat.
            if (standingY - high) / baselineWidth > tuning.up {
                reps.abandonRep()
                standingY = high
            }
            drop = (high - y) / baselineWidth
            if drop <= tuning.up { standingY = high }
            return reps.add(drop: drop, at: sample.time)
        }
    }
}

private extension SquatTracker {
    /// The frame's shoulder sample, unless it cannot be compared with the baseline: while counting,
    /// much narrower shoulders are someone in the background and much wider or narrower ones are
    /// the same person at another distance. Rejected long enough, the tracker starts over where
    /// the person now stands.
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
