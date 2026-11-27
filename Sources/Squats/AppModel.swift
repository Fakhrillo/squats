import AppKit
import Combine
import SquatsKit
import UserNotifications

/// Owns the ledger, the 30-second sitting tick and the reminder notification.
@MainActor
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Settings live in UserDefaults under these keys; views bind to the same keys with @AppStorage.
    static let defaultSettings: [String: Any] = [
        "perSet": 10, "intervalMinutes": 30, "maxOwed": 30, "soundOn": true,
        "depth": SquatTracker.Tuning().down,
        "hoursOn": false, "startHour": 9, "endHour": 18, "weekdaysOnly": true,
        "idleMinutes": 5,   // no UI: `defaults write io.github.fakhrillo.squats idleMinutes -int N`
        "stravaPrivate": true,
    ]
    private static let tickSeconds: TimeInterval = 30
    private static let noticeID = "squats.due"

    @Published private(set) var ledger: Ledger { didSet { save() } }
    @Published var sessionOpen = false
    /// "Pause for an hour". Kept in UserDefaults so it survives a relaunch.
    @Published private(set) var pause: Pause {
        didSet { defaults.set(pause.until?.timeIntervalSince1970 ?? 0, forKey: "pausedUntil") }
    }

    /// Off until the user connects it.
    let strava = StravaAccount()
    /// Opening one of the app's windows from the menu closes the menu.
    let closeMenu = PassthroughSubject<Void, Never>()

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
        let pausedUntil = defaults.double(forKey: "pausedUntil")
        pause = Pause(until: pausedUntil > 0 ? Date(timeIntervalSince1970: pausedUntil) : nil)
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
        // Paused or outside working hours: no sitting time counts and nothing is announced.
        let quiet = quiet() != nil
        let present = !quiet && (sessionOpen || inCall || Presence.idleSeconds() < idleLimit)
        // Always the constant tick length, never a wall-clock difference: sleep cannot inflate it.
        let due = ledger.tick(seconds: Self.tickSeconds, present: present, today: Self.dayKey(),
                              perSet: perSet,
                              interval: TimeInterval(defaults.integer(forKey: "intervalMinutes") * 60),
                              maxOwed: defaults.integer(forKey: "maxOwed"))
        if gate.shouldPost(due: due, hold: inCall, drop: sessionOpen || quiet) { postNotice() }
        strava.sendFinishedDays(ledger)
    }

    // MARK: Working hours and pause

    /// Why reminders are not running right now, if they are not.
    enum Quiet { case paused(until: Date), outsideHours }

    func quiet(at now: Date = Date()) -> Quiet? {
        if pause.isActive(at: now), let until = pause.until { return .paused(until: until) }
        let schedule = Schedule(enabled: defaults.bool(forKey: "hoursOn"),
                                startHour: defaults.integer(forKey: "startHour"),
                                endHour: defaults.integer(forKey: "endHour"),
                                weekdaysOnly: defaults.bool(forKey: "weekdaysOnly"))
        return schedule.isActive(at: now) ? nil : .outsideHours
    }

    func togglePause() {
        if pause.isActive(at: Date()) { pause.stop() } else { pause.start(at: Date(), for: 3600) }
    }

    private lazy var squatWindow = SquatWindow(model: self)

    func openSession(calibrating: Bool = false) {
        squatWindow.show(calibrating: calibrating)
    }

    private let stravaWindow = StravaWindow()

    func openStrava() {
        closeMenu.send()
        stravaWindow.show(model: self)
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

    /// The ledger's name for a day: "yyyy-MM-dd" in local time.
    static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"   // local time zone by default
        return formatter.string(from: date)
    }

    // MARK: Notification

    private func postNotice() {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.body = ledger.noticeText(perSet: perSet)
        content.categoryIdentifier = "squats"
        content.sound = defaults.bool(forKey: "soundOn") ? .default : nil
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
