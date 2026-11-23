import ServiceManagement
import SquatsKit
import SwiftUI

@main
struct SquatsApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: "figure.strengthtraining.functional")
            if model.ledger.owed > 0 { Text("\(model.ledger.owed)") }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuView: View {
    @ObservedObject var model: AppModel
    @AppStorage("perSet") private var perSet = 10
    @AppStorage("intervalMinutes") private var intervalMinutes = 30
    @AppStorage("maxOwed") private var maxOwed = 30
    @AppStorage("soundOn") private var soundOn = true
    @AppStorage("depth") private var depth = SquatTracker.Tuning().down
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Owed \(model.ledger.owed) · Done today \(model.ledger.doneToday)").font(.headline)
            Text("Next set in \(minutesLeft) min").foregroundStyle(.secondary)
            Button("Do squats now") { model.openSession() }
            Divider()
            Stepper("Squats per set: \(perSet)", value: $perSet, in: 1...30)
            Stepper("Every \(intervalMinutes) min", value: $intervalMinutes, in: 1...120)
            Stepper("Carry-over cap: \(maxOwed)", value: $maxOwed, in: 10...100)
            Toggle("Sound", isOn: $soundOn)
            LabeledContent("Squat depth") { Slider(value: $depth, in: 0.3...1.2) }
            Toggle("Start at login", isOn: Binding(
                get: { startAtLogin },
                set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    startAtLogin = SMAppService.mainApp.status == .enabled   // show what actually happened
                }))
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 270)
    }

    private var minutesLeft: Int {
        max(0, Int(((Double(intervalMinutes) * 60 - model.ledger.elapsed) / 60).rounded(.up)))
    }
}
