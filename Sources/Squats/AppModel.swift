import AppKit
import SquatsKit
import UserNotifications

/// Owns the ledger, the 30-second sitting tick and the reminder notification.
@MainActor
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Settings live in UserDefaults under these keys; views bind to the same keys with @AppStorage.
    static let defaultSettings: [String: Any] = [
        "perSet": 10, "intervalMinutes": 30, "maxOwed": 30, "soundOn": true,
        "depth": SquatTracker.Tuning().down,
        "idleMinutes": 5,   // no UI: `defaults write local.squats idleMinutes -int N`
    ]
    private static let tickSeconds: TimeInterval = 30
    private static let noticeID = "squats.due"

    @Published private(set) var ledger: Ledger { didSet { save() } }
    @Published var sessionOpen = false

    private let defaults = UserDefaults.standard
    private var gate = NoticeGate()
    private var timer: Timer?
    /// UNUserNotificationCenter traps in a process without a bundle (e.g. `swift run`).
    private let canNotify = Bundle.main.bundleIdentifier != nil

    override init() {
        defaults.register(defaults: Self.defaultSettings)
        // Unreadable saved state starts from an empty ledger rather than crashing.
        ledger = defaults.data(forKey: "ledger")
            .flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
        super.init()
    }

    func start() {
        if canNotify {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.setNotificationCategories([UNNotificationCategory(
                identifier: "squats",
                actions: [UNNotificationAction(identifier: "start", title: "Start", options: [.foreground]),
                          UNNotificationAction(identifier: "skip", title: "Skip", options: [])],
                intentIdentifiers: [])])
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let timer = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() {
        // In a video call: still sitting, so time counts, but the reminder waits until it ends.
        let inCall = !sessionOpen && Presence.cameraInUseElsewhere()
        let idleLimit = TimeInterval(defaults.integer(forKey: "idleMinutes") * 60)
        let present = sessionOpen || inCall || Presence.idleSeconds() < idleLimit
        // Always the constant tick length, never a wall-clock difference: sleep cannot inflate it.
        let due = ledger.tick(seconds: Self.tickSeconds, present: present, today: Self.today(),
                              perSet: perSet,
                              interval: TimeInterval(defaults.integer(forKey: "intervalMinutes") * 60),
                              maxOwed: defaults.integer(forKey: "maxOwed"))
        if gate.shouldPost(due: due, inCall: inCall, sessionOpen: sessionOpen) { postNotice() }
    }

    private lazy var squatWindow = SquatWindow(model: self)

    func openSession() {
        squatWindow.show()
    }

    func recordSquat() {
        ledger.recordSquat()
    }

    func sessionEnded(reachedTarget: Bool) {
        ledger.sessionEnded(reachedTarget: reachedTarget)
        // No stale "time for squats" banner left behind after a set.
        if canNotify {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.noticeID])
        }
    }

    var perSet: Int { defaults.integer(forKey: "perSet") }

    private func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "ledger") }
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"   // local time zone by default
        return formatter.string(from: Date())
    }

    // MARK: Notification

    private func postNotice() {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.body = ledger.noticeText(perSet: perSet)
        content.categoryIdentifier = "squats"
        content.sound = .default
        // Fixed identifier: a new reminder replaces the previous one.
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: Self.noticeID, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard action == "start" || action == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.openSession() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
