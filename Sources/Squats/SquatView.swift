import SquatsKit
import SwiftUI

/// The squat window: the camera picture with everything drawn over it, sized to read from a
/// couple of metres away.
struct SquatView: View {
    @ObservedObject var session: SquatSession

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch session.cameraState {
                case .denied:
                    CameraProblem(text: "Camera access is off for Squats") {
                        Button("Open Camera Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                        }
                    }
                case .noCamera:
                    CameraProblem(text: "Built-in camera not available. Is the lid closed?") { EmptyView() }
                case .starting, .running:
                    CameraPreview(session: session.camera.session, tick: session.frame?.time)
                        .overlay { SquatOverlay(session: session) }
                }
            }
            .frame(width: 640, height: 360)
            .background(.black)
            .clipped()

            HStack {
                Text("\(Duration.seconds(session.live.seconds).formatted(.time(pattern: .minuteSecond))) · \(session.doneToday) done today")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Done for now") { session.close() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

enum Palette {
    /// Light enough to read as lines over a camera picture.
    static let coral = Color(red: 240 / 255, green: 153 / 255, blue: 123 / 255)
    static let green = Color(red: 93 / 255, green: 202 / 255, blue: 165 / 255)
}

/// Everything drawn over the camera picture. Separate from `SquatView` so it can be rendered
/// without a camera.
struct SquatOverlay: View {
    @ObservedObject var session: SquatSession

    var body: some View {
        let live = session.live
        let counting = live.phase == .counting
        ZStack {
            if let summary = session.summary {
                FinishCard(summary: summary)
            } else {
                if !counting { Color.black.opacity(live.framing == .good ? 0 : 0.35) }
                FigureView(frame: session.frame, smoother: session.figure,
                           color: (counting ? live.deepEnough : live.framing == .good) ? Palette.green : Palette.coral,
                           guideScale: !counting && live.framing != .good ? live.sizeAtGoodSpot : nil)
                if counting {
                    CountingHUD(count: session.count, target: session.target, depth: live.depth,
                                deepEnough: live.deepEnough, cameUpShort: session.cameUpShort)
                } else {
                    SetupGuide(framing: live.framing, stillProgress: live.stillProgress)
                    Ripple(trigger: session.reachedGoodSpot).position(chest ?? CGPoint(x: 320, y: 180))
                }
                Flash(trigger: session.reachedGoodSpot + session.count)
                GoBurst(trigger: session.started)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: counting)
        .animation(.easeInOut(duration: 0.25), value: live.framing == .good)
    }

    /// The shoulder midpoint in overlay points (the overlay is as large as the 640 × 360 picture).
    private var chest: CGPoint? {
        guard let frame = session.frame, let sample = frame.sample(minConfidence: 0.3),
              let left = frame.leftShoulder, let right = frame.rightShoulder else { return nil }
        return CGPoint(x: (1 - (left.x + right.x) / 2 / PoseCamera.aspect) * 640, y: (1 - sample.y) * 360)
    }
}

// MARK: The figure

/// Eases the drawn joints toward the tracked ones, so the figure glides at the screen's frame rate
/// although poses arrive about 14 times a second.
final class FigureSmoother {
    typealias JointPath = KeyPath<PoseFrame, Joint?>
    static let joints: [JointPath] = Array(Set(PoseFrame.bones.flatMap { [$0.0, $0.1] })) + [\.nose, \.neck]

    private var points: [JointPath: CGPoint] = [:]
    private var last: Date?

    /// Where to draw each visible joint at `date`, in a view of `size`. The picture is mirrored.
    func step(toward frame: PoseFrame?, size: CGSize, at date: Date) -> [JointPath: CGPoint] {
        let pull = 1 - exp(-20 * (last.map { date.timeIntervalSince($0) } ?? 1))   // most of the gap in 50 ms
        last = date
        var next: [JointPath: CGPoint] = [:]
        for path in Self.joints {
            guard let joint = frame?[keyPath: path], joint.confidence >= 0.3 else { continue }
            let target = CGPoint(x: (1 - joint.x / PoseCamera.aspect) * size.width, y: (1 - joint.y) * size.height)
            let from = points[path] ?? target
            next[path] = CGPoint(x: from.x + (target.x - from.x) * pull, y: from.y + (target.y - from.y) * pull)
        }
        points = next
        return next
    }
}

/// A stick figure on the person's own joints. With `guideScale`, also a dashed outline of the
/// size they should shrink (or grow) to.
private struct FigureView: View {
    let frame: PoseFrame?
    let smoother: FigureSmoother
    let color: Color
    let guideScale: Double?

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let points = smoother.step(toward: frame, size: size, at: timeline.date)
                guard let left = points[\.leftShoulder], let right = points[\.rightShoulder] else { return }
                let width = hypot(left.x - right.x, left.y - right.y)
                let headRadius = width * 0.38

                var figure = Path()
                for (a, b) in PoseFrame.bones {
                    guard let p = points[a], let q = points[b] else { continue }
                    figure.move(to: p)
                    figure.addLine(to: q)
                }
                if let nose = points[\.nose] {
                    figure.addEllipse(in: CGRect(x: nose.x - headRadius, y: nose.y - headRadius,
                                                 width: headRadius * 2, height: headRadius * 2))
                    if let neck = points[\.neck] {   // from the neck to the edge of the head
                        let length = max(1, hypot(neck.x - nose.x, neck.y - nose.y))
                        figure.move(to: neck)
                        figure.addLine(to: CGPoint(x: nose.x + (neck.x - nose.x) / length * headRadius,
                                                   y: nose.y + (neck.y - nose.y) / length * headRadius))
                    }
                }
                context.stroke(figure, with: .color(.black.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                context.stroke(figure, with: .color(color),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                for (path, point) in points where path != \PoseFrame.nose {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
                                 with: .color(.white))
                }

                guard let guideScale, let nose = points[\.nose] else { return }
                let middle = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
                func scaled(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: middle.x + (p.x - middle.x) * guideScale, y: middle.y + (p.y - middle.y) * guideScale)
                }
                let (l, r, head, radius) = (scaled(left), scaled(right), scaled(nose), headRadius * guideScale)
                var guide = Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius,
                                                   width: radius * 2, height: radius * 2))
                guide.move(to: CGPoint(x: l.x, y: l.y + width * guideScale))
                guide.addLine(to: l)
                guide.addLine(to: r)
                guide.addLine(to: CGPoint(x: r.x, y: r.y + width * guideScale))
                context.stroke(guide, with: .color(.white),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [8, 7]))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Before counting

/// Says where to stand, and how far that is from here.
private struct SetupGuide: View {
    let framing: Framing?
    let stillProgress: Double

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            switch framing {
            case nil:
                headline("Stand in view, about two steps back")
            case .good?:
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.3), lineWidth: 6)
                        Circle().trim(from: 0, to: stillProgress)
                            .stroke(Palette.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.1), value: stillProgress)
                    }
                    .frame(width: 38, height: 38)
                    headline("Perfect spot. Hold still")
                }
            case .tooClose(let steps)?:
                headline(steps >= 1.5 ? "Step back about \(Int(steps.rounded())) steps"
                         : steps >= 0.75 ? "Step back one step" : "A little further back")
                StepMeter(stepsLeft: steps)
            case .tooFar(let steps)?:
                headline(steps >= 1.5 ? "Come about \(Int(steps.rounded())) steps closer"
                         : steps >= 0.75 ? "Come one step closer" : "A little closer")
                StepMeter(stepsLeft: steps)
            }
        }
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 4)
    }
}

/// A bar that fills as the good spot gets nearer; full is there. Three steps away or more is empty.
private struct StepMeter: View {
    let stepsLeft: Double

    var body: some View {
        let progress = 1 - min(stepsLeft, 3) / 3
        HStack(spacing: 12) {
            Image(systemName: "figure.stand").foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Palette.coral).frame(width: 14 + 266 * progress)
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
            .frame(width: 280, height: 14)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
        }
        .font(.system(size: 24, weight: .semibold))
        .shadow(color: .black.opacity(0.6), radius: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(progress * 100)) percent of the way to a good spot")
    }
}

// MARK: While counting

private struct CountingHUD: View {
    let count, target: Int
    let depth: Double
    let deepEnough: Bool
    let cameUpShort: Int
    @State private var shortUntil = Date.distantPast

    var body: some View {
        ZStack {
            CountRing(count: count, target: target)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            DepthBar(depth: depth, deepEnough: deepEnough)
                .padding(.trailing, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            Text(hint)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(deepEnough ? .black : .white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(deepEnough ? AnyShapeStyle(Palette.green) : AnyShapeStyle(.black.opacity(0.6)),
                            in: Capsule())
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onChange(of: cameUpShort) { shortUntil = Date().addingTimeInterval(2.5) }
    }

    /// Re-read with every camera frame, so the two-second hint needs no timer of its own.
    private var hint: String {
        if deepEnough { return "Deep enough, come up" }
        if Date() < shortUntil { return "Go a little deeper" }
        switch target - count {
        case target: return "Squat down to the line"
        case 1: return "Last one"
        case let left: return "\(left) to go"
        }
    }
}

/// The ring from the app icon: one step fuller with every squat.
private struct CountRing: View {
    let count, target: Int

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.5))
            Circle().stroke(.white.opacity(0.2), lineWidth: 9).padding(5)
            Circle().trim(from: 0, to: Double(count) / Double(max(1, target)))
                .stroke(MenuView.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(5)
            VStack(spacing: -4) {
                Text("\(count)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(target)").font(.system(size: 15, weight: .medium)).opacity(0.8)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 116, height: 116)
        .animation(.snappy, value: count)
        .keyframeAnimator(initialValue: 1.0, trigger: count) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(1.22, duration: 0.14)
                SpringKeyframe(1.0, duration: 0.4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) of \(target) squats")
    }
}

/// Fills from the top as the shoulders go down; green from the line on, where the squat counts.
private struct DepthBar: View {
    let depth: Double
    let deepEnough: Bool
    private static let height = 230.0, line = 0.62   // the line sits 62 % of the way down

    var body: some View {
        VStack(spacing: 6) {
            Text("Depth")
            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(deepEnough ? Palette.green : .white)
                    .frame(height: max(16, Self.height * min(1, depth * Self.line)))
                    .animation(.linear(duration: 0.1), value: depth)
                Rectangle().fill(.white)
                    .frame(width: 34, height: 3)
                    .offset(y: Self.height * Self.line)
                    .overlay(alignment: .topTrailing) {
                        Text("Target").fixedSize().offset(x: -42, y: Self.height * Self.line - 8)
                    }
            }
            .frame(width: 16, height: Self.height)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deepEnough ? "Deep enough" : "Not deep enough yet")
    }
}

// MARK: Moments

private struct Pulse {
    var scale = 0.4
    var opacity = 0.0
}

/// Two rings spreading from the chest when the person reaches a good spot.
private struct Ripple: View {
    let trigger: Int

    var body: some View {
        ZStack {
            ring(after: 0.01)
            ring(after: 0.2)
        }
        .allowsHitTesting(false)
    }

    private func ring(after delay: Double) -> some View {
        Circle().stroke(Palette.green, lineWidth: 7)
            .frame(width: 110, height: 110)
            .keyframeAnimator(initialValue: Pulse(), trigger: trigger) { view, pulse in
                view.scaleEffect(pulse.scale).opacity(pulse.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.4, duration: delay)
                    CubicKeyframe(3.0, duration: 0.8)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.0, duration: delay)
                    LinearKeyframe(0.95, duration: 0.06)
                    LinearKeyframe(0.0, duration: 0.74)
                }
            }
    }
}

/// A green edge that lights up for a moment: at the good spot, and on every counted squat.
private struct Flash: View {
    let trigger: Int

    var body: some View {
        Rectangle().strokeBorder(Palette.green, lineWidth: 10)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.95, duration: 0.08)
                    LinearKeyframe(0.0, duration: 0.45)
                }
            }
            .allowsHitTesting(false)
    }
}

private struct GoBurst: View {
    let trigger: Int

    var body: some View {
        Text("Go!")
            .font(.system(size: 110, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 6)
            .keyframeAnimator(initialValue: Pulse(scale: 0.5), trigger: trigger) { view, pulse in
                view.scaleEffect(pulse.scale).opacity(pulse.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.0, duration: 0.3)
                    LinearKeyframe(1.25, duration: 0.6)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1.0, duration: 0.1)
                    LinearKeyframe(1.0, duration: 0.45)
                    LinearKeyframe(0.0, duration: 0.35)
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: After the set

private struct FinishCard: View {
    let summary: SquatSession.Summary
    @State private var drawn = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(MenuView.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .symbolEffect(.bounce, value: drawn)
            }
            .frame(width: 104, height: 104)
            Text("\(counted(summary.squats, "squat")) in \(counted(summary.seconds, "second"))")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("\(summary.doneToday) done today · "
                 + (summary.stillOwed == 0 ? "all caught up" : "\(summary.stillOwed) still owed"))
                .font(.system(size: 18, weight: .medium))
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.6))
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { drawn = true } }
    }

    private func counted(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

private struct CameraProblem<Action: View>: View {
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash").font(.system(size: 44))
            Text(text).font(.title2.weight(.semibold))
            action
        }
        .foregroundStyle(.white)
    }
}
