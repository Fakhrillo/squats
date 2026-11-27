import ServiceManagement
import SquatsKit
import SwiftUI

/// The popover under the menu-bar icon: where you stand, one button to start a set, and the
/// settings folded away because they are rarely touched.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @AppStorage("perSet") private var perSet = 10
    @AppStorage("intervalMinutes") private var intervalMinutes = 30
    @AppStorage("maxOwed") private var maxOwed = 30
    @AppStorage("soundOn") private var soundOn = true
    @AppStorage("depth") private var depth = SquatTracker.Tuning().down
    @AppStorage("hoursOn") private var hoursOn = false
    @AppStorage("startHour") private var startHour = 9
    @AppStorage("endHour") private var endHour = 18
    @AppStorage("weekdaysOnly") private var weekdaysOnly = true
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showSettings: Bool

    /// The coral of the app icon, deep enough to carry white text.
    static let accent = Color(red: 208 / 255, green: 67 / 255, blue: 31 / 255)

    init(model: AppModel, settingsOpen: Bool = false) {
        self.model = model
        _showSettings = State(initialValue: settingsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
            week

            Button(model.ledger.actionText(perSet: perSet)) { model.openSession() }
                .buttonStyle(PrimaryButtonStyle())

            Divider()

            VStack(spacing: 2) {
                MenuRow(action: { model.togglePause() }) {
                    Text(isPaused ? "Resume reminders" : "Pause for an hour")
                    Spacer()
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                MenuRow(action: { showSettings.toggle() }) {
                    Text("Settings")
                    Spacer()
                    Image(systemName: showSettings ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if showSettings { settings }
                MenuRow(action: { NSApp.terminate(nil) }) {
                    Text("Quit Squats")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: Status

    /// The ring from the app icon as a live countdown: it fills as the sitting interval passes.
    private var status: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 6)
                Circle().trim(from: 0, to: progress)
                    .stroke(Self.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(model.ledger.owed)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 66, height: 66)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int(progress * 100)) percent of the way to the next set")

            VStack(alignment: .leading, spacing: 3) {
                Text(model.ledger.statusText).font(.headline)
                Text(timerLine).foregroundStyle(.secondary)
                Text("\(model.ledger.doneToday) done today").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Squats per day for the last seven days; today is the coral bar on the right.
    private var week: some View {
        let days = (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        let counts = days.map { model.ledger.done(on: AppModel.dayKey($0)) }
        let most = max(counts.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(zip(days, counts).enumerated()), id: \.offset) { index, day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == days.count - 1 ? Self.accent : Color.primary.opacity(0.22))
                        .frame(height: max(3, 30 * Double(day.1) / Double(most)))
                    Text(day.0.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(index == days.count - 1 ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(day.0.formatted(.dateTime.weekday(.wide))): \(day.1) squats")
            }
        }
        .frame(height: 48, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Squats in the last seven days: " + zip(days, counts).map {
            "\($0.formatted(.dateTime.weekday(.wide))) \($1)"
        }.joined(separator: ", "))
    }

    private var interval: Double { Double(intervalMinutes) * 60 }
    private var progress: Double { model.ledger.progress(interval: interval) }
    private var minutesLeft: Int { max(0, Int(((interval - model.ledger.elapsed) / 60).rounded(.up))) }

    private var isPaused: Bool {
        if case .paused = model.quiet() { return true }
        return false
    }

    /// The timer line says why nothing is counting when reminders are off.
    private var timerLine: String {
        switch model.quiet() {
        case .paused(let until): return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        case .outsideHours: return "Outside working hours"
        case nil: return "Next set in \(minutesLeft) min"
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: 9) {
            stepperRow("Squats per set", value: $perSet, in: 1...30, shown: "\(perSet)")
            stepperRow("Remind every", value: $intervalMinutes, in: 5...120, step: 5,
                       shown: "\(intervalMinutes) min")
            stepperRow("Owe at most", value: $maxOwed, in: 10...100, step: 5, shown: "\(maxOwed) squats")
            switchRow("Working hours only", isOn: $hoursOn)
            if hoursOn {
                Group {   // indented: these only apply while working hours are on
                    stepperRow("From", value: $startHour, in: 0...23, shown: "\(startHour):00")
                    stepperRow("Until", value: $endHour, in: 0...23, shown: "\(endHour):00")
                    switchRow("Weekdays only", isOn: $weekdaysOnly)
                }
                .padding(.leading, 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Squat depth")
                    Spacer()
                    // Three squats in front of the camera set the slider from how deep you go.
                    Button("Calibrate…") { model.openSession(calibrating: true) }
                        .controlSize(.small)
                }
                Slider(value: $depth, in: SquatTracker.Tuning.depthRange) {
                    Text("Squat depth")
                } minimumValueLabel: {
                    Text("Shallower").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Deeper").font(.caption).foregroundStyle(.secondary)
                }
                .labelsHidden()
            }
            switchRow("Sound", isOn: $soundOn)
            switchRow("Start at login", isOn: Binding(
                get: { startAtLogin },
                set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    startAtLogin = SMAppService.mainApp.status == .enabled   // show what actually happened
                }))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func stepperRow(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>,
                            step: Int = 1, shown: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shown).foregroundStyle(.secondary).monospacedDigit()
            Stepper(title, value: value, in: range, step: step).labelsHidden()
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Self.accent)
        }
    }
}

/// The one filled control in the menu. A custom style, so it keeps the icon's coral whether or not
/// macOS considers the popover the active window (system prominent buttons turn grey when it is not).
private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(MenuView.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

/// A full-width row that highlights under the pointer, like a menu item.
private struct MenuRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack { label }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(hovering ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
