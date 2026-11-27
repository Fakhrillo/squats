import Foundation
import Testing
@testable import SquatsKit

private let app = Strava.App(clientID: "1234", clientSecret: "s3cret&more")
private let fake = URL(string: "http://127.0.0.1:9")!

private func fields(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), String(parts[1]).removingPercentEncoding ?? "")
    })
}

@Test func theSignInPageIsAskedForPermissionToAddWorkoutsOnly() throws {
    let url = Strava.authorizeURL(clientID: "1234", redirect: URL(string: "http://127.0.0.1:53682/strava")!, state: "abc")
    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(parts.host == "www.strava.com"); #expect(parts.path == "/oauth/authorize")
    #expect(query == ["client_id": "1234", "redirect_uri": "http://127.0.0.1:53682/strava", "response_type": "code",
                      "approval_prompt": "auto", "scope": "activity:write", "state": "abc"])
}

@Test func theBrowsersAnswerIsReadStrictly() {
    func answer(_ query: String) -> Strava.Callback { Strava.callback(URL(string: "http://127.0.0.1:53682/strava?\(query)")!, state: "abc") }
    #expect(answer("state=abc&code=xyz&scope=read,activity:write") == .code("xyz"))
    #expect(answer("state=abc&error=access_denied") == .denied)
    #expect(answer("state=abc&code=xyz&scope=read") == .withoutPermission)     // they unticked "upload"
    #expect(answer("state=other&code=xyz&scope=read,activity:write") == .unrelated)   // not our sign-in
    #expect(answer("code=xyz&scope=activity:write") == .unrelated)
    #expect(answer("state=abc&code=&scope=activity:write") == .unrelated)
}

@Test func aCodeOrARefreshTokenIsExchangedForTokens() {
    let first = Strava.tokenRequest(site: fake, app: app, grant: .code("xyz"))
    #expect(first.url?.absoluteString == "http://127.0.0.1:9/oauth/token"); #expect(first.httpMethod == "POST")
    #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(fields(first) == ["client_id": "1234", "client_secret": "s3cret&more", "grant_type": "authorization_code", "code": "xyz"])
    let again = Strava.tokenRequest(site: fake, app: app, grant: .refresh("r1"))
    #expect(fields(again) == ["client_id": "1234", "client_secret": "s3cret&more", "grant_type": "refresh_token", "refresh_token": "r1"])
}

@Test func stravasTokenAnswerIsUnderstood() throws {       // the example from Strava's documentation
    let answer = Data(#"{"token_type":"Bearer","access_token":"a9b723","expires_at":1568775134,"expires_in":20566,"refresh_token":"b5c569"}"#.utf8)
    let tokens = try JSONDecoder().decode(Strava.Tokens.self, from: answer)
    #expect(tokens == Strava.Tokens(accessToken: "a9b723", refreshToken: "b5c569", expiresAt: 1568775134))
    #expect(tokens.isFresh(at: Date(timeIntervalSince1970: 1568775134 - 3600)))
    #expect(!tokens.isFresh(at: Date(timeIntervalSince1970: 1568775134 - 30)))
    #expect(try JSONDecoder().decode(Strava.Tokens.self, from: JSONEncoder().encode(tokens)) == tokens)
}

@Test func aDaysSquatsBecomeOneWorkout() {
    let request = Strava.activityRequest(site: fake, accessToken: "tok", squats: 120, start: "2026-11-26T18:00:00Z", keepPrivate: true)
    #expect(request.url?.absoluteString == "http://127.0.0.1:9/api/v3/activities"); #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(fields(request) == ["name": "Squats", "sport_type": "WeightTraining", "start_date_local": "2026-11-26T18:00:00Z",
                                "elapsed_time": "360", "description": "120 squats, counted by the Squats app for Mac",
                                "visibility": "only_me"])
    let shared = Strava.activityRequest(site: fake, accessToken: "tok", squats: 1, start: "2026-11-26T18:00:00Z", keepPrivate: false)
    #expect(fields(shared)["visibility"] == nil); #expect(fields(shared)["description"] == "1 squat, counted by the Squats app for Mac")
}

@Test func disconnectingRevokesTheTokenWithTheAppsOwnCredentials() {
    let request = Strava.revokeRequest(site: fake, app: app, token: "r1")
    #expect(request.url?.absoluteString == "http://127.0.0.1:9/oauth/revoke"); #expect(fields(request) == ["token": "r1"])
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("1234:s3cret&more".utf8).base64EncodedString())
}

@Test func onlySquatsNotYetSentAreSent() {
    var log = StravaLog()
    #expect(log.unsent(done: 40, on: "2026-11-26") == 40)
    log.record(40, on: "2026-11-26")
    #expect(log.unsent(done: 40, on: "2026-11-26") == 0); #expect(log.unsent(done: 55, on: "2026-11-26") == 15)
    #expect(log.unsent(done: 10, on: "2026-11-26") == 0)        // never negative
    log.record(15, on: "2026-11-26"); #expect(log.unsent(done: 55, on: "2026-11-26") == 0)
    for day in 1...20 { log.record(1, on: String(format: "2026-12-%02d", day)) }
    #expect(log.sent.count == 8); #expect(log.sent["2026-12-20"] == 1); #expect(log.sent["2026-11-26"] == nil)
}
