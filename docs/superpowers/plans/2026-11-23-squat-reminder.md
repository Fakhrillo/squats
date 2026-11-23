# Squat Reminder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac menu-bar app that asks for a set of squats every 30 minutes of laptop time, counts them with the built-in camera, and rolls missed squats into the next set.

**Architecture:** One Swift package. A library target, `SquatsKit`, holds everything that can be tested without a person: the owed-squats ledger, the rep counter, the pose-frame type, and the camera-to-pose pipeline. A thin executable, `Squats`, adds the menu-bar UI, the 30-second presence tick, notifications and the squat window. A throwaway executable, `PoseSpike`, records real squats first so thresholds come from measurement.

**Tech Stack:** Swift 6.4 (language mode 5), SwiftUI `MenuBarExtra`, AVFoundation, Vision `DetectHumanBodyPoseRequest`, UserNotifications, CoreMediaIO, ServiceManagement, Swift Testing. No third-party packages.

**Spec:** `docs/superpowers/specs/2026-11-23-squat-reminder-design.md`

## Global Constraints

- Deployment target macOS 15.0; `swift-tools-version: 6.0`; `swiftLanguageModes: [.v5]`.
- No third-party dependencies. No network requests anywhere.
- The camera session runs only while the squat window (or the spike) is open.
- Built-in camera only: `AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)`.
- No image or video is ever written to disk. The spike writes joint coordinates only.
- Storage is `UserDefaults` only. Bundle id `local.squats` (spike: `local.squats.spike`).
- Defaults: `perSet` 10 (range 1–30), `intervalMinutes` 30, `maxOwed` 30, `idleMinutes` 5, tick 30 s, down threshold 0.7, up threshold 0.2, minimum rep 0.5 s.
- Sign with the `Apple Development` certificate in the keychain. No hardened runtime, no sandbox.
- Git: `git init` in Task 1, one local commit per task. No remote, no push.

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Targets: `SquatsKit`, `PoseSpike`, `Squats`, `SquatsKitTests` |
| `scripts/bundle.sh` | Build a target, wrap it in a signed `.app` |
| `Sources/SquatsKit/PoseFrame.swift` | Joints of one camera frame, CSV line, shoulder sample, nearest person, conversion from a Vision observation |
| `Sources/SquatsKit/PoseCamera.swift` | Built-in camera → Vision → `PoseFrame`; mirrored preview view with joint dots |
| `Sources/SquatsKit/SquatTracker.swift` | `RepCounter` (two thresholds) and `SquatTracker` (stand-still baseline, smoothing, tuning) |
| `Sources/SquatsKit/Ledger.swift` | `owed`, `doneToday`, countdown, day reset, notification text |
| `Sources/PoseSpike/PoseSpikeApp.swift` | Throwaway recorder, deleted in Task 8 |
| `Sources/Squats/SquatsApp.swift` | `@main`, menu-bar item, settings popover |
| `Sources/Squats/AppModel.swift` | Persistence, 30 s tick, notifications |
| `Sources/Squats/Presence.swift` | Input idle seconds, camera in use by another app |
| `Sources/Squats/SquatWindow.swift` | The squat session window |
| `Tests/SquatsKitTests/*.swift`, `Fixtures/*.csv` | Unit tests and recorded squats |

## Review Focus

1. **A colleague walks behind you mid-set.** The counter must keep following you, the nearest person. Pinned by `nearestPicksWidestShoulders` (Task 1).
2. **A late timer, or the interval setting shortened mid-run.** One tick must never add more than one set. Pinned by `oneTickNeverAccruesMoreThanOneSet` and `loweredCapClampsOwed` (Task 3).
3. **You step out of frame, or walk back to the laptop, mid-set.** No phantom squat; the count so far is kept. Pinned by `leavingTheFrameRebaselinesAndKeepsTheCount` and the `walk` recording (Task 4).
4. **Camera permission denied, or the lid is closed on an external display.** The window says what is wrong instead of showing a black box, and reminders keep working. Pinned by the manual checks in Task 6.
5. **Notifications denied, or saved state unreadable.** The menu-bar count still works, and the app starts from an empty ledger instead of crashing. Pinned by the manual checks in Task 5.

---

### Task 1: Package and pose frame

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/SquatsKit/PoseFrame.swift`
- Test: `Tests/SquatsKitTests/PoseFrameTests.swift`

**Interfaces:**
- Produces:

```swift
public struct Joint: Equatable {            // x, y in units of image HEIGHT, origin bottom-left, y grows upward
    public var x, y, confidence: Double
    public init(x: Double, y: Double, confidence: Double)
}
public struct PoseSample: Equatable { public var time: TimeInterval; public var y: Double; public var width: Double }
public struct PoseFrame: Equatable {
    public var time: TimeInterval
    public var nose, neck, leftShoulder, rightShoulder, leftHip, rightHip: Joint?
    public init(time: TimeInterval)
    public static let csvHeader: String     // "t,nose_x,nose_y,nose_c,neck_…,lsh_…,rsh_…,lhip_…,rhip_…" (19 columns)
    public var csvLine: String              // "%.5f" per number, empty fields for a nil joint
    public init?(csvLine: String)           // nil for the header or a malformed line
    public func sample(minConfidence: Double) -> PoseSample?
    public static func nearest(_ frames: [PoseFrame]) -> PoseFrame?
}
```

- [ ] **Step 1: Scaffold.** `git init`. `.gitignore`: `.build/`, `build/`, `recordings/`. `Package.swift` with library target `SquatsKit` and test target `SquatsKitTests`, per Global Constraints.

- [ ] **Step 2: Write the failing tests**

```swift
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
}
```

- [ ] **Step 3: Run** `swift test --filter PoseFrameTests`. Expected: fails to compile, `PoseFrame` not found.

- [ ] **Step 4: Implement `PoseFrame.swift`** to the interface above. `sample` returns the shoulder midpoint `y` and the straight-line shoulder distance; `nearest` compares that distance at `minConfidence: 0` and skips frames without both shoulders.

- [ ] **Step 5: Run** `swift test --filter PoseFrameTests`. Expected: 4 tests pass.

- [ ] **Step 6: Commit** `git add -A && git commit -m "feat: package scaffold and pose frame"`

---

### Task 2: Camera pipeline and recording spike

Needs the user at the camera for about ten minutes. Tasks 3 and 5 do not depend on the recordings and can be built while waiting.

**Files:**
- Create: `scripts/bundle.sh`, `Sources/SquatsKit/PoseCamera.swift`, `Sources/PoseSpike/PoseSpikeApp.swift`
- Modify: `Package.swift` (add executable target `PoseSpike` depending on `SquatsKit`), `Sources/SquatsKit/PoseFrame.swift` (add Vision conversion), the spec (append findings)

**Interfaces:**
- Consumes: `PoseFrame`, `Joint`, `PoseFrame.nearest` from Task 1.
- Produces:

```swift
extension PoseFrame {   // x = location.x * aspect, y = location.y
    public init(_ observation: HumanBodyPoseObservation, time: TimeInterval, aspect: Double)
}
public final class PoseCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public enum StartResult { case running, denied, noCamera }
    public static let aspect = 16.0 / 9.0          // session preset .hd1280x720
    public let session: AVCaptureSession
    public var onFrame: ((PoseFrame) -> Void)?     // main queue; nearest person, or a frame with no joints when nobody is seen
    public func start() async -> StartResult       // asks for camera permission on first use
    public func stop()
}
public struct CameraPreview: View {                // mirrored preview at 16:9 with a dot per joint of confidence ≥ 0.3
    public init(session: AVCaptureSession, frame: PoseFrame?)
}
```

- [ ] **Step 1: Write `scripts/bundle.sh <Squats|PoseSpike>`.** `swift build -c release --product "$1"`, assemble `build/$1.app` (`Contents/MacOS/$1`, generated `Contents/Info.plist`), then `codesign --force --sign "Apple Development"`. Plist keys: `CFBundleIdentifier` (`local.squats`, or `local.squats.spike` for the spike), `CFBundleName`, `CFBundleExecutable`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `1.0`, `CFBundleVersion` `1`, `LSMinimumSystemVersion` `15.0`, `LSUIElement` (true only for `Squats`), `NSCameraUsageDescription` "Squats uses the camera only while you are doing a set, to count your squats. Nothing is recorded or sent."

- [ ] **Step 2: Implement `PoseCamera` and `CameraPreview`.** One Vision request in flight at a time; drop frames that arrive meanwhile (`alwaysDiscardsLateVideoFrames = true`). Frame time is the sample buffer's presentation timestamp in seconds. Several people in view: convert every observation and emit `PoseFrame.nearest`. Preview layer mirrored; dots drawn at `(1 − x / aspect, 1 − y)` of the view.

- [ ] **Step 3: Implement the recorder `PoseSpikeApp.swift`.** One window: `CameraPreview`, a live readout (shoulder `y`, shoulder `width`, confidence of nose / neck / shoulders / hips), a picker with labels `squats-1m`, `squats-1.5m`, `squats-2m`, `idle`, `walk`, and a Record button. Record: 5-second on-screen countdown, beep, 25 seconds of `csvLine` rows written to `NSTemporaryDirectory()/<label>.csv` (header first, overwrite), beep. No command-line arguments: a bare path after `open --args` stops SwiftUI from creating the window.

- [ ] **Step 4: Build and launch.** `scripts/bundle.sh PoseSpike && open build/PoseSpike.app`; clips are collected afterwards with `cp "$(getconf DARWIN_USER_TEMP_DIR)"/{squats-*,idle,walk}.csv recordings/`. Expected: camera permission prompt, then preview with dots on head and shoulders. Squatting must make the shoulder `y` readout go down; if it goes up, flip `y` to `1 − y` in the Vision conversion.

- [ ] **Step 5: The user records five clips**, lid at its usual angle, each starting with two seconds standing still facing the laptop:
  - `squats-1m`, `squats-1.5m`, `squats-2m`: exactly 5 squats at a normal pace, at that distance from the screen.
  - `idle`: at the most comfortable of those distances, shift weight, look around, reach for something. No squats, no sitting.
  - `walk`: stand at that distance, walk to the laptop, walk back.

- [ ] **Step 6: Analyse the recordings.** For each `squats-*` file: share of frames with both shoulders at confidence ≥ 0.3; baseline `y` and `width` as medians of the first 1.5 s; `drop = (baselineY − y) / baselineWidth` per frame; the five peak drops. Decide:
  - A distance is **usable** when shoulders are confident in ≥ 90% of frames and five separate peaks are visible. The recommended distance is the nearest usable one.
  - `down` = 0.6 × the smallest peak at the recommended distance, rounded to 2 places. `up` = 0.3 × `down`.
  - `stillTolerance` stays 0.1 unless the first two seconds of any usable clip range wider; then use twice the widest range.
  - `idle` must never reach `down`.
  - **Stop and return to the user** if no distance is usable or `idle` reaches `down`. Report the visibility table and the options from the spec (track nose or neck, track the face box, tilt the lid); Task 4 gets amended with their choice.

- [ ] **Step 7: Record the findings.** Append a "Spike findings" section to the spec: visibility per distance, recommended distance, `down`, `up`, `stillTolerance`. Copy the usable `squats-*.csv`, `idle.csv` and `walk.csv` to `Tests/SquatsKitTests/Fixtures/`.

- [ ] **Step 8: Commit** `git add -A && git commit -m "feat: camera pipeline, recorder spike and recorded squats"`

---

### Task 3: Ledger

**Files:**
- Create: `Sources/SquatsKit/Ledger.swift`
- Test: `Tests/SquatsKitTests/LedgerTests.swift`

**Interfaces:**
- Produces:

```swift
public struct Ledger: Codable, Equatable {
    public var owed = 0, doneToday = 0
    public var elapsed: TimeInterval = 0     // present seconds counted toward the next set
    public var day = ""                      // "yyyy-MM-dd" of the last tick
    public init()
    /// Returns true when this tick completed an interval (a set became due).
    public mutating func tick(seconds: TimeInterval, present: Bool, today: String,
                              perSet: Int, interval: TimeInterval, maxOwed: Int) -> Bool
    public mutating func recordSquat()                       // owed − 1 (floor 0), doneToday + 1
    public mutating func sessionEnded(reachedTarget: Bool)   // restarts the countdown when reachedTarget && owed == 0
    public func target(perSet: Int) -> Int                   // owed if > 0, else perSet
    public func noticeText(perSet: Int) -> String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run** `swift test --filter LedgerTests`. Expected: fails to compile, `Ledger` not found.

- [ ] **Step 3: Implement `Ledger.swift`.** Order inside `tick`: day change first (clear `owed`, `doneToday`, `elapsed`), then add `seconds` when present, then at most one accrual: `if elapsed >= interval { elapsed = 0; owed = min(owed + perSet, maxOwed); return true }`. `noticeText`: with `carried = owed − perSet`, return "\(owed) squats — \(carried) carried over" when `carried > 0`, otherwise "Time for \(owed) squats".

- [ ] **Step 4: Run** `swift test --filter LedgerTests`. Expected: 12 tests pass.

- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: owed-squats ledger"`

---

### Task 4: Rep counter and squat tracker

**Files:**
- Create: `Sources/SquatsKit/SquatTracker.swift`
- Modify: `Package.swift` (test target `resources: [.copy("Fixtures")]`)
- Test: `Tests/SquatsKitTests/SquatTrackerTests.swift`

**Interfaces:**
- Consumes: `PoseFrame.sample(minConfidence:)`, the fixtures and the measured `down`, `up`, `stillTolerance` from Task 2.
- Produces:

```swift
public struct RepCounter {
    public init(down: Double, up: Double, minDuration: TimeInterval)
    public private(set) var count: Int
    public mutating func add(drop: Double, at time: TimeInterval) -> Bool   // true when this sample completes a rep
}
public struct SquatTracker {
    public struct Tuning {            // down, up, stillTolerance: replace with Task 2's measured values
        public var down = 0.7, up = 0.2, minRepDuration = 0.5, minConfidence = 0.3
        public var stillSeconds = 1.0, stillTolerance = 0.1, lostSeconds = 3.0
        public var smoothing = 3
        public init()
    }
    public enum Phase { case searching, calibrating, counting }
    public init(tuning: Tuning = Tuning())
    public private(set) var phase: Phase
    public private(set) var drop: Double       // last smoothed drop, in shoulder widths
    public var count: Int { get }
    public mutating func add(_ frame: PoseFrame) -> Bool    // true when this frame completes a rep
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import SquatsKit

private func counted(_ drops: [Double], dt: Double = 0.2) -> (count: Int, hits: [Bool]) {
    var c = RepCounter(down: 0.7, up: 0.2, minDuration: 0.5)
    let hits = drops.enumerated().map { c.add(drop: $1, at: Double($0) * dt) }
    return (c.count, hits)
}
@Test func fullCycleCountsOnceOnTheWayUp() {
    let r = counted([0, 0.4, 0.8, 0.8, 0.4, 0.1])
    #expect(r.hits == [false, false, false, false, false, true]); #expect(r.count == 1)
}
@Test func shallowDipDoesNotCount()            { #expect(counted([0, 0.4, 0.6, 0.4, 0.1]).count == 0) }
@Test func wobbleAtTheBottomCountsOnce()       { #expect(counted([0, 0.8, 0.65, 0.8, 0.65, 0.8, 0.1]).count == 1) }
@Test func glitchShorterThanHalfASecondIsIgnored() { #expect(counted([0, 0.9, 0], dt: 0.05).count == 0) }
@Test func neverComingBackUpCountsNothing()    { #expect(counted([0, 0.5, 0.9, 0.9, 0.9]).count == 0) }
@Test func fiveSquatsCountFive() {
    #expect(counted(Array(repeating: [0.1, 0.5, 0.9, 0.5, 0.1], count: 5).flatMap { $0 }).count == 5)
}

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

private func count(fixture name: String) throws -> Int {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"))
    var tracker = SquatTracker()
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        if let f = PoseFrame(csvLine: String(line)) { _ = tracker.add(f) }
    }
    return tracker.count
}
// Arguments: the squats-* files Task 2 marked usable.
@Test(arguments: ["squats-1m", "squats-1.5m", "squats-2m"])
func recordedSquatsCountExactlyFive(name: String) throws { let n = try count(fixture: name); #expect(n == 5) }
@Test(arguments: ["idle", "walk"])
func recordedMovementCountsZero(name: String) throws { let n = try count(fixture: name); #expect(n == 0) }
```

- [ ] **Step 2: Run** `swift test --filter SquatTrackerTests`. Expected: fails to compile, `RepCounter` not found.

- [ ] **Step 3: Implement `RepCounter`.** A rep starts when `drop` first rises above `up`, is armed once `drop ≥ down`, and ends when `drop ≤ up`. It counts only if armed and `end − start ≥ minDuration`. Either way the state resets to standing.

- [ ] **Step 4: Implement `SquatTracker`,** with `Tuning` defaults set to Task 2's measured `down`, `up` and `stillTolerance`:
  - No sample (`frame.sample(minConfidence:)` is nil): ignore the frame. If the last good sample is older than `lostSeconds`, go to `.searching` and forget the baseline; `count` stays.
  - `.searching` + good sample → `.calibrating`.
  - `.calibrating`: append the sample to a window, then drop the oldest samples until `max(y) − min(y) ≤ stillTolerance × mean(width)`. When `newest.time − oldest.time ≥ stillSeconds`, set `baselineY = mean(y)`, `baselineWidth = mean(width)` → `.counting`.
  - `.counting`: `drop = (baselineY − mean of the last `smoothing` sample ys) / baselineWidth`, fed to `RepCounter`.

- [ ] **Step 5: Run** `swift test`. Expected: every test passes. If `walk` counts a rep: treat a frame whose `width` differs from `baselineWidth` by more than a limit as "no sample", choosing the limit from the recordings so all squat frames stay inside and the walk leaves it; add the limit to `Tuning`. If no limit separates them, or a `squats-*` file does not give 5, stop and report to the user with the drop traces.

- [ ] **Step 6: Commit** `git add -A && git commit -m "feat: rep counter and squat tracker tuned on recordings"`

---

### Task 5: App shell — menu bar, sitting timer, notification

**Files:**
- Create: `Sources/Squats/SquatsApp.swift`, `Sources/Squats/AppModel.swift`, `Sources/Squats/Presence.swift`
- Modify: `Package.swift` (executable target `Squats` depending on `SquatsKit`)

**Interfaces:**
- Consumes: `Ledger` (Task 3).
- Produces:

```swift
enum Presence {
    static func idleSeconds() -> TimeInterval   // min of CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)
                                                // over .keyDown, .mouseMoved, .leftMouseDown, .scrollWheel
}
@MainActor final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var ledger: Ledger
    @Published var sessionOpen = false
    func start()                                // register defaults, ask notification permission, start the 30 s Timer
    func tick()
    func openSession()                          // empty in this task; Task 6 makes it show the window
    func recordSquat()
    func sessionEnded(reachedTarget: Bool)
}
```

`UserDefaults` keys and defaults: `ledger` (JSON `Data`), `perSet` 10, `intervalMinutes` 30, `maxOwed` 30, `soundOn` true, `depth` (`SquatTracker.Tuning().down`), `idleMinutes` 5 (no UI). Views bind with `@AppStorage` on the same keys.

- [ ] **Step 1: Implement `Presence.idleSeconds()` and `AppModel`.** An unreadable `ledger` value loads as `Ledger()`. Every mutation saves. `tick()` is:

```swift
let inCall = false                                            // Task 7 replaces this
let present = sessionOpen || inCall || Presence.idleSeconds() < idleMinutes * 60
if ledger.tick(seconds: 30, present: present, today: today, perSet: perSet,
               interval: intervalMinutes * 60, maxOwed: maxOwed) { noticePending = true }
if sessionOpen { noticePending = false }                      // quiet accrual during a set
if noticePending && !inCall { postNotice(); noticePending = false }
```

The tick always passes the constant 30, never a wall-clock difference. `today` is `yyyy-MM-dd` in the local time zone.

- [ ] **Step 2: Implement the notification.** Fixed request identifier `squats.due` so a new one replaces the old. Body `ledger.noticeText(perSet:)`. Category with actions `start` ("Start", opens the app) and `skip` ("Skip"). `didReceive`: `start` or a click on the banner calls `openSession()`; `skip` does nothing. `willPresent` returns `[.banner, .sound]`.

- [ ] **Step 3: Implement `SquatsApp`.** `MenuBarExtra` with `.menuBarExtraStyle(.window)`. Label: SF Symbol `figure.strengthtraining.functional`, followed by the owed count when above 0. Popover, top to bottom: "Owed N · Done today N", "Next set in N min", button "Do squats now", stepper "Squats per set" 1–30, stepper "Every N min" 1–120, stepper "Carry-over cap" 10–100, toggle "Sound", slider "Squat depth" 0.3–1.2, button "Quit".

- [ ] **Step 4: Build and launch.** `scripts/bundle.sh Squats && open build/Squats.app`. Expected: a figure icon in the menu bar, a notification-permission prompt, no Dock icon.

- [ ] **Step 5: Manual checks.** Set "Every" to 1 min and run `defaults write local.squats idleMinutes -int 1`, then relaunch.
  - Keep typing for a minute: the icon shows 10, and a banner reads "Time for 10 squats" with Start and Skip.
  - Press Skip, keep typing another minute: 20, banner "20 squats — 10 carried over".
  - Hands off for three minutes: the count rises by at most one set, then stops.
  - Quit and relaunch: the count is unchanged.
  - Reading idle time triggers no permission prompt (Accessibility or Input Monitoring).
  - Turn notifications off for Squats in System Settings: the menu-bar count still climbs.
  - `defaults write local.squats ledger -string garbage`, relaunch: starts at 0, no crash.
  - `defaults delete local.squats idleMinutes` when finished.

- [ ] **Step 6: Commit** `git add -A && git commit -m "feat: menu-bar app with sitting timer and reminder"`

---

### Task 6: Squat window

**Files:**
- Create: `Sources/Squats/SquatWindow.swift`
- Modify: `Sources/Squats/AppModel.swift` (`openSession()` shows the window)

**Interfaces:**
- Consumes: `PoseCamera`, `CameraPreview` (Task 2); `SquatTracker` (Task 4); `AppModel.recordSquat()`, `sessionEnded(reachedTarget:)`, `ledger.target(perSet:)` (Tasks 3, 5).
- Produces: `@MainActor final class SquatWindow: NSObject, NSWindowDelegate { init(model: AppModel); func show() }`

- [ ] **Step 1: Implement `SquatWindow`.** A 360-point-wide floating window (`level = .floating`) titled "Squats": `CameraPreview`, the count as "7 / 20" in large type, a status line, and a "Done for now" button.
  - On `show()`: `target = model.ledger.target(perSet:)`, fixed for the session; tracker built with `Tuning.down = depth`; `model.sessionOpen = true`; start the camera.
  - Status by `tracker.phase`: `.searching` "Step back until your head and shoulders are in frame", `.calibrating` "Stand still…", `.counting` "Keep going".
  - Each rep: `model.recordSquat()`, sound `Tink` when `soundOn`. At `target`: sound `Glass`, close after 1.5 s.
  - On close, by any route: stop the camera, `model.sessionOpen = false`, `model.sessionEnded(reachedTarget:)`, and remove the delivered `squats.due` notification so no stale banner lingers.
  - `.denied`: no preview; text "Camera access is off for Squats." and a button opening `x-apple.systempreferences:com.apple.preference.security?Privacy_Camera`.
  - `.noCamera`: text "Built-in camera not available. Is the lid closed?"
  - A second `openSession()` while open brings the existing window forward.

- [ ] **Step 2: Build and launch** `scripts/bundle.sh Squats && open build/Squats.app`.

- [ ] **Step 3: Manual checks** (the user does the squats).
  - "Do squats now" with nothing owed: target 10. Ten squats at the recommended distance count as ten, the window closes, the camera light goes off, "Next set in" shows the full interval.
  - With 20 owed, do 6 and press "Done for now": 14 owed; the next interval makes it 24.
  - Start from the notification's Start button and by clicking the banner: both open the window.
  - Walk out of frame mid-set and back: status returns to "Step back…", then "Stand still…", and the count resumes from where it was.
  - Let an interval come due while the window is open: no banner, the on-screen target does not change.
  - `tccutil reset Camera local.squats`, relaunch, deny the prompt: the denied message appears and the button opens the right settings pane.

- [ ] **Step 4: Commit** `git add -A && git commit -m "feat: camera-counted squat session"`

---

### Task 7: Call awareness and start at login

**Files:**
- Modify: `Sources/Squats/Presence.swift`, `Sources/Squats/AppModel.swift`, `Sources/Squats/SquatsApp.swift`

**Interfaces:**
- Produces: `static func cameraInUseElsewhere() -> Bool` on `Presence`: true when any CoreMediaIO device (`kCMIOHardwarePropertyDevices` on `kCMIOObjectSystemObject`) reports `kCMIODevicePropertyDeviceIsRunningSomewhere`.

- [ ] **Step 1: Implement `cameraInUseElsewhere()`** and replace the placeholder in `tick()` with `let inCall = !sessionOpen && Presence.cameraInUseElsewhere()`.

- [ ] **Step 2: Add the "Start at login" toggle** above Quit, bound to `SMAppService.mainApp.status == .enabled`, calling `register()` / `unregister()`.

- [ ] **Step 3: Manual checks**, with "Every" at 1 min.
  - Open Photo Booth, hands off the keyboard for three minutes: no banner, and the menu-bar count rises each minute.
  - Quit Photo Booth: the banner arrives within 30 seconds.
  - Open the squat window: `sessionOpen` keeps the app's own camera use from counting as a call (the session behaves as in Task 6).
  - `cp -R build/Squats.app /Applications/`, launch from there, turn on "Start at login", log out and in: the icon is back.

- [ ] **Step 4: Commit** `git add -A && git commit -m "feat: hold reminders during calls, start at login"`

---

### Task 8: Remove the spike, write the README

**Files:**
- Delete: `Sources/PoseSpike/`
- Modify: `Package.swift` (remove the `PoseSpike` target), `scripts/bundle.sh` (drop the spike branch)
- Create: `README.md`

- [ ] **Step 1: Delete the spike** and its target. `swift test` and `scripts/bundle.sh Squats` both succeed.

- [ ] **Step 2: Write `README.md`**, about fifteen lines: what the app does, `scripts/bundle.sh Squats` then copy to `/Applications`, the recommended standing distance from the spike, what the "Squat depth" slider does, the `idleMinutes` override, and the privacy statement from the spec.

- [ ] **Step 3: Commit** `git add -A && git commit -m "chore: remove recorder spike, add README"`

After this the spec's last phase starts: a day of real use, then adjust depth and defaults.
