import SquatsKit
import SwiftUI

/// The Strava window: how to connect, and once connected, what is sent.
struct StravaView: View {
    @ObservedObject var account: StravaAccount
    @ObservedObject var model: AppModel
    @AppStorage("stravaClientID") private var clientID = ""
    @AppStorage("stravaPrivate") private var keepPrivate = true
    @State private var clientSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch account.status {
            case .connected: connected
            case .connecting: waiting
            case .disconnected, .failed: setup
            }
        }
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var setup: some View {
        Group {
            Text("Send each day's squats to Strava").font(.headline)
            Text("Squats makes no network requests unless you connect here. After that it talks to Strava only, to sign in and to add one workout a day. Nothing from the camera is sent.")
                .foregroundStyle(.secondary)
            step(1, "Create an API application on Strava. The name, website and icon can be anything; type **localhost** as the Authorization Callback Domain.")
            Button("Open Strava's API settings") { NSWorkspace.shared.open(Strava.apiSettings) }
                .padding(.leading, 24)
            step(2, "Paste the two values Strava then shows:")
            Group {
                TextField("Client ID", text: $clientID)
                SecureField("Client Secret", text: $clientSecret)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.leading, 24)
            step(3, "Connect, and allow Squats on the page that opens in your browser.")
            Button("Connect") { account.connect(clientID: clientID, clientSecret: clientSecret) }
                .buttonStyle(.borderedProminent)
                .tint(MenuView.accent)
                .padding(.leading, 24)
            if case .failed(let why) = account.status {
                Text(why).foregroundStyle(.red)
            }
        }
    }

    private var waiting: some View {
        Group {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to allow Squats on Strava's page in your browser.")
            }
            Button("Cancel") { account.cancelConnecting() }
        }
    }

    private var connected: some View {
        let unsent = account.unsentToday(model.ledger)
        return Group {
            Label("Connected to Strava", systemImage: "checkmark.circle.fill").font(.headline)
            Text("Each morning the squats of the day before are added as one workout. Today's can be sent early, below.")
                .foregroundStyle(.secondary)
            Toggle("Keep these workouts private (Only You)", isOn: $keepPrivate)
            HStack(spacing: 10) {
                Button(unsent > 0 ? "Send today's \(unsent) squats now" : "Nothing new to send") {
                    Task { await account.sendToday(model.ledger) }
                }
                .disabled(unsent == 0 || account.sending)
                if account.sending { ProgressView().controlSize(.small) }
            }
            if !account.note.isEmpty { Text(account.note).foregroundStyle(.secondary) }
            Divider()
            Button("Disconnect") { account.disconnect() }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
            Text(text)
        }
    }
}

/// An ordinary window, so it stays open while you copy values over from the browser.
@MainActor
final class StravaWindow {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: StravaView(account: model.strava, model: model)))
            window.title = "Strava"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            SquatWindow.centre(window)
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
