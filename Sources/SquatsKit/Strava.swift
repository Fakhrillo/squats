import Foundation

/// The parts of the Strava connection that need no network: the requests it sends and how it reads
/// the answers. The app only ever adds workouts; it asks for no permission to read anything.
public enum Strava {
    public static let site = URL(string: "https://www.strava.com")!
    /// Where someone creates the API application whose ID and secret the app needs.
    public static let apiSettings = URL(string: "https://www.strava.com/settings/api")!
    static let permission = "activity:write"
    // ponytail: a workout needs a length and nothing times the squats across a day. The recorded
    // clip took 25 s for ten; store real set durations in the ledger if the estimate matters.
    public static let secondsPerSquat = 3

    /// The user's own API application on Strava. A new one is limited to its owner's account.
    public struct App: Equatable {
        public var clientID, clientSecret: String
        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID; self.clientSecret = clientSecret
        }
    }

    public struct Tokens: Codable, Equatable {
        public var accessToken, refreshToken: String
        /// Seconds since 1970. Access tokens last six hours.
        public var expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at"
        }

        public init(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
            self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        }

        /// Good for at least another minute.
        public func isFresh(at now: Date = Date()) -> Bool { expiresAt - now.timeIntervalSince1970 > 60 }
    }

    /// The page on which the user allows the app to add workouts.
    public static func authorizeURL(site: URL = site, clientID: String, redirect: URL, state: String) -> URL {
        var parts = URLComponents(url: site.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
                            URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "approval_prompt", value: "auto"),
                            URLQueryItem(name: "scope", value: permission),
                            URLQueryItem(name: "state", value: state)]
        return parts.url!
    }

    public enum Callback: Equatable {
        case code(String)
        case denied
        /// Signed in, but with "upload activities" unticked: the app could do nothing with it.
        case withoutPermission
        /// Not the answer to this sign-in: ignore it and keep waiting.
        case unrelated
    }

    /// Reads the address Strava sent the browser back to. `state` is the value this sign-in started
    /// with: anything else that reaches the local address is not ours.
    public static func callback(_ url: URL, state: String) -> Callback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { return .unrelated }
        if value("error") != nil { return .denied }
        guard let code = value("code"), !code.isEmpty else { return .unrelated }
        guard (value("scope") ?? "").split(separator: ",").contains(Substring(permission)) else { return .withoutPermission }
        return .code(code)
    }

    public enum Grant: Equatable {
        /// The one-time code from the sign-in.
        case code(String)
        case refresh(String)
    }

    public static func tokenRequest(site: URL = site, app: App, grant: Grant) -> URLRequest {
        var fields = [("client_id", app.clientID), ("client_secret", app.clientSecret)]
        switch grant {
        case .code(let code): fields += [("grant_type", "authorization_code"), ("code", code)]
        case .refresh(let token): fields += [("grant_type", "refresh_token"), ("refresh_token", token)]
        }
        return post(site.appendingPathComponent("oauth/token"), fields)
    }

    /// One workout holding a day's squats. `start` is local time as "yyyy-MM-ddTHH:mm:ssZ".
    public static func activityRequest(site: URL = site, accessToken: String, squats: Int, start: String,
                                       keepPrivate: Bool) -> URLRequest {
        var fields = [("name", "Squats"), ("sport_type", "WeightTraining"), ("start_date_local", start),
                      ("elapsed_time", String(squats * secondsPerSquat)),
                      ("description", "\(squats) squat\(squats == 1 ? "" : "s"), counted by the Squats app for Mac")]
        // Without this the workout gets whatever the account's default visibility is.
        if keepPrivate { fields.append(("visibility", "only_me")) }
        var request = post(site.appendingPathComponent("api/v3/activities"), fields)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Ends the app's access; Strava also removes it from the account's list of connected apps.
    public static func revokeRequest(site: URL = site, app: App, token: String) -> URLRequest {
        var request = post(site.appendingPathComponent("oauth/revoke"), [("token", token)])
        let login = Data("\(app.clientID):\(app.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Local time the way Strava's `start_date_local` wants it.
    public static func localStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    private static func post(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: plain) ?? "" }
        request.httpBody = Data(fields.map { "\(encoded($0.0))=\(encoded($0.1))" }.joined(separator: "&").utf8)
        return request
    }
}

/// How many squats of each day have already gone to Strava, so that nothing is sent twice.
public struct StravaLog: Codable, Equatable {
    public private(set) var sent: [String: Int] = [:]

    public init() {}

    public func unsent(done: Int, on day: String) -> Int { max(0, done - (sent[day] ?? 0)) }

    public mutating func record(_ squats: Int, on day: String) {
        sent[day, default: 0] += squats
        // Only the last week is ever looked at again.
        sent = Dictionary(uniqueKeysWithValues: sent.sorted { $0.key > $1.key }.prefix(8).map { ($0.key, $0.value) })
    }
}
