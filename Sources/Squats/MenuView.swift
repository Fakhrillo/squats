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
            stepperRow("Remind every", value: $intervalMinutes, in: 1...120, shown: "\(intervalMinutes) min")
            stepperRow("Carry-over cap", value: $maxOwed, in: 10...100, shown: "\(maxOwed)")
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
                Text("Squat depth")
                Slider(value: $depth, in: 0.3...1.2) {
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
                            shown: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shown).foregroundStyle(.secondary).monospacedDigit()
            Stepper(title, value: value, in: range).labelsHidden()
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
