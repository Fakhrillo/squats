import Foundation
import Vision

/// One body joint. `x` and `y` are in units of image height, origin bottom-left, y grows upward.
public struct Joint: Equatable {
    public var x, y, confidence: Double
    public init(x: Double, y: Double, confidence: Double) {
        self.x = x; self.y = y; self.confidence = confidence
    }
}

/// What the squat tracker needs from a frame: how high the shoulders are and how far apart.
public struct PoseSample: Equatable {
    public var time: TimeInterval
    public var y: Double
    public var width: Double
}

/// The joints of the nearest person in one camera frame.
public struct PoseFrame: Equatable {
    public var time: TimeInterval
    public var nose, neck, leftShoulder, rightShoulder, leftHip, rightHip: Joint?
    /// Arms and legs, for drawing the figure only: the tracker ignores them and they are not in the CSV.
    public var leftElbow, rightElbow, leftWrist, rightWrist, leftKnee, rightKnee, leftAnkle, rightAnkle: Joint?

    /// The joint pairs to connect when drawing the figure (the head is drawn around the nose).
    public static let bones: [(KeyPath<PoseFrame, Joint?>, KeyPath<PoseFrame, Joint?>)] = [
        (\.leftShoulder, \.rightShoulder), (\.leftHip, \.rightHip),
        (\.leftShoulder, \.leftHip), (\.rightShoulder, \.rightHip),
        (\.leftShoulder, \.leftElbow), (\.leftElbow, \.leftWrist),
        (\.rightShoulder, \.rightElbow), (\.rightElbow, \.rightWrist),
        (\.leftHip, \.leftKnee), (\.leftKnee, \.leftAnkle),
        (\.rightHip, \.rightKnee), (\.rightKnee, \.rightAnkle),
    ]

    public init(time: TimeInterval) { self.time = time }

    private static let columns: [(name: String, path: WritableKeyPath<PoseFrame, Joint?>)] = [
        ("nose", \.nose), ("neck", \.neck), ("lsh", \.leftShoulder), ("rsh", \.rightShoulder),
        ("lhip", \.leftHip), ("rhip", \.rightHip),
    ]

    public static let csvHeader =
        "t," + columns.map { "\($0.name)_x,\($0.name)_y,\($0.name)_c" }.joined(separator: ",")

    public var csvLine: String {
        func f(_ v: Double) -> String { String(format: "%.5f", v) }
        let joints = Self.columns.flatMap { column -> [String] in
            guard let j = self[keyPath: column.path] else { return ["", "", ""] }
            return [f(j.x), f(j.y), f(j.confidence)]
        }
        return ([f(time)] + joints).joined(separator: ",")
    }

    /// Nil for the header or a malformed line.
    public init?(csvLine: String) {
        let fields = csvLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 1 + Self.columns.count * 3, let t = Double(fields[0]) else { return nil }
        self.init(time: t)
        for (i, column) in Self.columns.enumerated() {
            let at = 1 + i * 3
            if let x = Double(fields[at]), let y = Double(fields[at + 1]), let c = Double(fields[at + 2]) {
                self[keyPath: column.path] = Joint(x: x, y: y, confidence: c)
            }
        }
    }

    /// Shoulder midpoint height and shoulder distance; nil unless both shoulders are confident.
    public func sample(minConfidence: Double) -> PoseSample? {
        guard let l = leftShoulder, let r = rightShoulder,
              l.confidence >= minConfidence, r.confidence >= minConfidence else { return nil }
        return PoseSample(time: time, y: (l.y + r.y) / 2, width: hypot(l.x - r.x, l.y - r.y))
    }

    /// The person closest to the camera: widest shoulders win. Falls back to the first person
    /// when nobody's shoulders are in view.
    public static func nearest(_ frames: [PoseFrame]) -> PoseFrame? {
        let withShoulders = frames.compactMap { f in f.sample(minConfidence: 0).map { (f, $0.width) } }
        return withShoulders.max { $0.1 < $1.1 }?.0 ?? frames.first
    }
}

extension PoseFrame {
    /// `aspect` is image width / height: Vision normalizes x to the width, we want height units.
    public init(_ observation: HumanBodyPoseObservation, time: TimeInterval, aspect: Double) {
        self.init(time: time)
        func joint(_ name: HumanBodyPoseObservation.JointName) -> Joint? {
            guard let j = observation.joint(for: name), j.confidence > 0 else { return nil }
            return Joint(x: j.location.x * aspect, y: j.location.y, confidence: Double(j.confidence))
        }
        nose = joint(.nose)
        neck = joint(.neck)
        leftShoulder = joint(.leftShoulder)
        rightShoulder = joint(.rightShoulder)
        leftHip = joint(.leftHip)
        rightHip = joint(.rightHip)
        leftElbow = joint(.leftElbow)
        rightElbow = joint(.rightElbow)
        leftWrist = joint(.leftWrist)
        rightWrist = joint(.rightWrist)
        leftKnee = joint(.leftKnee)
        rightKnee = joint(.rightKnee)
        leftAnkle = joint(.leftAnkle)
        rightAnkle = joint(.rightAnkle)
    }
}
