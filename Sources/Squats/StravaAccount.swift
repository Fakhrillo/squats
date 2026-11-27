import AppKit
import Network
import Security
import SquatsKit

/// The optional link to Strava, and the only code in the app that uses the network. Nothing here
/// runs until the user connects, and then it talks to Strava alone: to sign in and to add workouts.
@MainActor
final class StravaAccount: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, failed(String) }

    @Published private(set) var status = Status.disconnected
    /// What the last attempt to send did, in words for the window.
    @Published private(set) var note = ""
    @Published private(set) var sending = false

    /// Where the browser is sent back to after the sign-in: this Mac only.
    nonisolated static let port: UInt16 = 47917
    nonisolated static let redirect = URL(string: "http://127.0.0.1:\(port)/strava")!

    private let site: URL
    private let keychain: Keychain
    private let open: (URL) -> Void
    /// How long to wait for the browser to come back before giving the port up again.
    private let patience: TimeInterval
    private let defaults = UserDefaults.standard
    private let session = URLSession(configuration: .ephemeral)   // no cookies, no cache on disk
    private var listener: CallbackListener?
    private var retryAfter = Date.distantPast
    /// Days Strava refused outright. They are left out until the next launch so they cannot hold
    /// up the days after them.
    private var refused: Set<String> = []
    /// Goes up whenever the user connects, cancels or disconnects. Work that was waiting on Strava
    /// when that happened checks it and drops its result instead of saving it.
    private var generation = 0

    init(site: URL = Strava.site, keychain: Keychain = Keychain(service: "io.github.fakhrillo.squats.strava"),
         patience: TimeInterval = 300, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.site = site
        self.keychain = keychain
        self.patience = patience
        self.open = open
        if tokens != nil, app != nil { status = .connected }
    }

    // MARK: Connecting

    /// Waits on this Mac for Strava's answer, then opens Strava's sign-in page in the browser.
    func connect(clientID: String, clientSecret: String) {
        let app = Strava.App(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                             clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !app.clientID.isEmpty, !app.clientSecret.isEmpty else {
            status = .failed("Enter both the Client ID and the Client Secret.")
            return
        }
        generation += 1
        let attempt = generation, state = UUID().uuidString
        stopListening()
        let inUse = "Could not wait for Strava's answer: port \(Self.port) on this Mac is in use."
        do {
            listener = try CallbackListener(port: Self.port) { [weak self] ready in
                guard let self, self.generation == attempt, self.listener != nil else { return }
                if ready {   // only now is it certain that the answer will reach this app
                    self.open(Strava.authorizeURL(site: self.site, clientID: app.clientID, redirect: Self.redirect, state: state))
                } else {
                    self.stopListening()
                    self.status = .failed(inUse)
                }
            } onRequest: { [weak self] url in
                guard let self, self.generation == attempt else { return false }
                return self.answered(url, state: state, app: app, attempt: attempt)
            }
        } catch {
            status = .failed(inUse)
            return
        }
        status = .connecting
        Task {   // nobody finished the sign-in: stop listening
            try? await Task.sleep(for: .seconds(patience))
            guard generation == attempt, listener != nil else { return }
            stopListening()
            status = .failed("Strava's answer did not arrive. Connect again.")
        }
    }

    func cancelConnecting() {
        generation += 1
        stopListening()
        if status == .connecting { status = .disconnected }
    }

    /// True when `url` was the answer to this sign-in (whatever it said).
    private func answered(_ url: URL, state: String, app: Strava.App, attempt: Int) -> Bool {
        switch Strava.callback(url, state: state) {
        case .unrelated:
            return false
        case .denied:
            stopListening()
            status = .failed("Strava access was not allowed.")
        case .withoutPermission:
            stopListening()
            status = .failed("Squats needs “Upload your activities” left ticked on Strava's page. Connect again.")
        case .code(let code):
            stopListening()
            Task {
                do {
                    let tokens = try await exchange(.code(code), for: app)
                    guard generation == attempt else {   // cancelled while Strava was answering
                        revoke(tokens, of: app)
                        return
                    }
                    defaults.set(app.clientID, forKey: "stravaClientID")
                    // Earlier days stay out of Strava: connecting must not upload a week at once.
                    defaults.set(Self.today(), forKey: "stravaSince")
                    guard keychain.write(Data(app.clientSecret.utf8), "clientSecret"), save(tokens) else {
                        status = .failed("Could not save the connection in your keychain.")
                        return
                    }
                    note = ""
                    status = .connected
                } catch {
                    guard generation == attempt else { return }
                    status = .failed((error as? Failure)?.message ?? "Could not reach Strava. Check the connection and try again.")
                }
            }
        }
        return true
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
    }

    /// Ends Strava's access for this app and removes the secret, the tokens and the Client ID from
    /// this Mac. The record of what was sent stays, so that connecting again sends nothing twice.
    func disconnect() {
        generation += 1
        stopListening()
        if let app, let tokens { revoke(tokens, of: app) }
        forgetKeys()
        defaults.removeObject(forKey: "stravaClientID")
        note = ""
        status = .disconnected
    }

    /// Best effort: the keys are deleted from this Mac whether or not Strava hears about it.
    private func revoke(_ tokens: Strava.Tokens, of app: Strava.App) {
        let request = Strava.revokeRequest(site: site, app: app, token: tokens.refreshToken)
        Task { _ = try? await session.data(for: request) }
    }

    private func forgetKeys() {
        keychain.delete("tokens")
        keychain.delete("clientSecret")
    }

    // MARK: Sending

    private enum Outcome { case sent, refused, notNow }

    private static func today() -> String { String(Strava.localStamp(Date()).prefix(10)) }

    /// Squats of `day` that still have to go. Days before the connection was made never do.
    private func unsent(_ done: Int, on day: String) -> Int {
        day >= (defaults.string(forKey: "stravaSince") ?? "") ? log.unsent(done: done, on: day) : 0
    }

    func unsentToday(_ ledger: Ledger) -> Int { unsent(ledger.doneToday, on: ledger.day) }

    /// The "send now" button: the ledger's current day so far, as a workout that ends now.
    func sendToday(_ ledger: Ledger) async {
        let squats = unsentToday(ledger)
        guard squats > 0 else { return }
        // Just after midnight the ledger can still be on the day before: then it is a finished day.
        let start = ledger.day == Self.today()
            ? Strava.localStamp(Date().addingTimeInterval(-Double(squats * Strava.secondsPerSquat)))
            : Self.evening(of: ledger.day)
        await send(squats, on: ledger.day, start: start)
    }

    /// Called with every tick: sends finished days that have not gone yet, oldest first. Today is
    /// left alone until it is over, so that a day is one workout.
    func sendFinishedDays(_ ledger: Ledger) {
        guard status == .connected, !sending, Date() >= retryAfter else { return }
        let pending = ledger.history.sorted { $0.key < $1.key }
            .first { !refused.contains($0.key) && unsent($0.value, on: $0.key) > 0 }
        guard let pending else { return }
        Task {
            switch await send(unsent(pending.value, on: pending.key), on: pending.key, start: Self.evening(of: pending.key)) {
            case .sent: break
            case .refused: refused.insert(pending.key)
            case .notNow: retryAfter = Date().addingTimeInterval(15 * 60)   // offline, or Strava is down
            }
        }
    }

    /// A finished day's real times are not kept; early evening stands for "that day".
    private static func evening(of day: String) -> String { "\(day)T18:00:00Z" }

    @discardableResult
    private func send(_ squats: Int, on day: String, start: String) async -> Outcome {
        guard !sending else { return .notNow }
        sending = true
        defer { sending = false }
        do {
            let tokens = try await freshTokens()
            let request = Strava.activityRequest(site: site, accessToken: tokens.accessToken, squats: squats,
                                                 start: start, keepPrivate: defaults.bool(forKey: "stravaPrivate"))
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 201 else { throw Failure(code: code) }
            var log = log
            log.record(squats, on: day)
            defaults.set(try? JSONEncoder().encode(log), forKey: "stravaLog")
            note = "Sent \(squats) squat\(squats == 1 ? "" : "s") to Strava."
            return .sent
        } catch let failure as Failure {
            note = failure.message
            if failure.code == 401 {   // access was removed on Strava's side: nothing here works any more
                generation += 1
                forgetKeys()
                status = .failed("Strava no longer accepts this connection. Connect again.")
            } else if (400..<500).contains(failure.code), failure.code != 429 {
                return .refused
            }
        } catch is Unreadable {
            // Not the same as access removed: the keys may be there and macOS did not hand them over.
            note = "Could not read the Strava connection from your keychain. Allow it, or connect again."
        } catch is CancellationError {
            // Disconnected while this was under way: say nothing.
        } catch {
            note = "Could not reach Strava. It will be tried again later."
        }
        return .notNow
    }

    /// Access tokens last six hours; this trades the saved refresh token for a new one when needed.
    private func freshTokens() async throws -> Strava.Tokens {
        guard let app, let tokens else { throw Unreadable() }
        if tokens.isFresh() { return tokens }
        let attempt = generation
        let renewed = try await exchange(.refresh(tokens.refreshToken), for: app)
        guard generation == attempt else {   // disconnected meanwhile: do not bring the tokens back
            revoke(renewed, of: app)
            throw CancellationError()
        }
        _ = save(renewed)   // Strava may hand back a new refresh token; the old one then stops working
        return renewed
    }

    private func exchange(_ grant: Strava.Grant, for app: Strava.App) async throws -> Strava.Tokens {
        let (data, response) = try await session.data(for: Strava.tokenRequest(site: site, app: app, grant: grant))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let tokens = try? JSONDecoder().decode(Strava.Tokens.self, from: data) else {
            throw Failure(code: code)
        }
        return tokens
    }

    private struct Unreadable: Error {}

    struct Failure: Error {
        let code: Int
        var message: String {
            switch code {
            case 400, 401: return "Strava did not accept the Client ID, the Client Secret or the sign-in."
            case 429: return "Strava's request limit was reached. It will be tried again later."
            default: return "Strava answered with an error (\(code)). It will be tried again later."
            }
        }
    }

    // MARK: What is saved

    private var app: Strava.App? {
        guard let id = defaults.string(forKey: "stravaClientID"), !id.isEmpty,
              let secret = keychain.read("clientSecret") else { return nil }
        return Strava.App(clientID: id, clientSecret: String(decoding: secret, as: UTF8.self))
    }

    private var tokens: Strava.Tokens? {
        keychain.read("tokens").flatMap { try? JSONDecoder().decode(Strava.Tokens.self, from: $0) }
    }

    private func save(_ tokens: Strava.Tokens) -> Bool {
        (try? JSONEncoder().encode(tokens)).map { keychain.write($0, "tokens") } ?? false
    }

    private var log: StravaLog {
        defaults.data(forKey: "stravaLog").flatMap { try? JSONDecoder().decode(StravaLog.self, from: $0) } ?? StravaLog()
    }
}

/// The secret and the tokens live in the login keychain, never in the preferences file.
struct Keychain {
    let service: String

    private func item(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    func read(_ account: String) -> Data? {
        var found: AnyObject?
        let query = item(account).merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }
        return SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess ? found as? Data : nil
    }

    func write(_ data: Data, _ account: String) -> Bool {
        delete(account)
        return SecItemAdd(item(account).merging([kSecValueData: data]) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ account: String) {
        SecItemDelete(item(account) as CFDictionary)
    }
}

/// Listens on this Mac only (127.0.0.1) for the browser coming back from Strava's sign-in page.
final class CallbackListener {
    private let listener: NWListener

    /// `onState` hears once whether the port could be taken: creating the listener does not fail
    /// when another program already holds it, that only shows afterwards.
    /// `onRequest` gets the address the browser asked for and says whether it was the answer.
    init(port: UInt16, onState: @escaping @MainActor (_ ready: Bool) -> Void,
         onRequest: @escaping @MainActor (URL) -> Bool) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: MainActor.assumeIsolated { onState(true) }
            case .failed, .waiting: MainActor.assumeIsolated { onState(false) }
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            // Whoever connects and then says nothing is not kept waiting for ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                // The first line is "GET /strava?code=… HTTP/1.1".
                let words = String(decoding: data ?? Data(), as: UTF8.self).prefix { $0 != "\r" && $0 != "\n" }.split(separator: " ")
                let url = words.count >= 2 ? URL(string: "http://127.0.0.1\(words[1])") : nil
                let ours = url.map { url in MainActor.assumeIsolated { onRequest(url) } } ?? false
                let body = ours ? "<h3>Squats has Strava's answer.</h3><p>You can close this tab and go back to Squats.</p>" : "Not found"
                let head = "HTTP/1.1 \(ours ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
    }

    func cancel() { listener.cancel() }
}
