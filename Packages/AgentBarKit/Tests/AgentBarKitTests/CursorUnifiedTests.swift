import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentBarKit

/// Unified Cursor seats, from the shapes OpenUsage pinned in CursorUnifiedAccountTests
/// (SCO-181) and from the product split the Grok dashboard shows of the same pool.
@Suite("Cursor unified account")
struct CursorUnifiedTests {
    @Test func aMergedSeatShowsTheWeeklyPoolItsProductsAdditionalUsageAndCredits() throws {
        let period = """
        {"billingCycleEnd":"1795333076119","billingCycleStart":"1794728276119","enabled":true,
         "planUsage":{"autoPercentUsed":27,"totalPercentUsed":27}}
        """
        let plan = """
        {"isMerged":true,"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY",
         "includedUsageResetsAt":"1795333076119","planName":"Super"}}
        """
        let balance = #"{"usdRemainingCents":"581149"}"#
        let status = """
        {"availability":"available","monthlyUsage":{"additionalUsageOff":false,"limitCents":null,"usedCents":0,
         "periodStart":"2026-11-01T00:00:00.000Z","resetsAt":"2026-12-01T00:00:00.000Z"},
         "weeklyIncludedUsage":{"budgetCents":10000,"usedCents":2700,"resetsAt":"2026-11-22T07:37:56.119Z"},
         "weeklyIncludedUsageByProduct":[{"cents":1500,"product":"cursor"},{"cents":1200,"product":"grok_bot"}]}
        """
        let reading = CursorUnified.reading(period: Data(period.utf8), plan: Data(plan.utf8),
                                            balance: Data(balance.utf8), status: Data(status.utf8))
        #expect(reading.identity.plan == "Super")
        #expect(reading.limits.map(\.title) == ["Weekly", "Cursor", "Grok Bot", "Additional"])
        let weekly = try #require(reading.limits.first)
        #expect(weekly.percentUsed == 27)
        #expect(weekly.windowLength == 604_800.0)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_795_333_076.119))
        #expect(reading.limits[1].percentUsed == 15)
        #expect(reading.limits[2].percentUsed == 12)
        #expect(reading.limits[1].fullName == "share of the weekly pool")
        // No monthly cap: the row is the amount spent, including zero.
        #expect(reading.limits[3].amount == 0)
        #expect(reading.limits[3].percentUsed == 0)
        #expect(reading.credits?.caption == "$5811.49 credits")
    }

    @Test func additionalUsageWithACapIsAPercentThatResetsMonthly() throws {
        let status = """
        {"availability":"available","monthlyUsage":{"additionalUsageOff":false,"limitCents":10000,"usedCents":2500,
         "resetsAt":"2026-12-01T00:00:00.000Z","periodStart":"2026-11-01T00:00:00.000Z"}}
        """
        let reading = CursorUnified.reading(period: nil, plan: nil, balance: nil, status: Data(status.utf8))
        let additional = try #require(reading.limits.first { $0.title == "Additional" })
        #expect(additional.percentUsed == 25)
        #expect(additional.amount == nil)
        #expect(additional.resetsAt == ISODate.parse("2026-12-01T00:00:00.000Z"))
    }

    @Test func additionalUsageHidesWhenItIsOffOrTheCapIsZero() {
        for monthly in [
            #""additionalUsageOff":true,"limitCents":null,"usedCents":0"#,
            #""limitCents":0,"usedCents":0"#,
        ] {
            let status = #"{"availability":"available","monthlyUsage":{\#(monthly)}}"#
            let reading = CursorUnified.reading(period: nil, plan: nil, balance: Data(#"{}"#.utf8), status: Data(status.utf8))
            #expect(reading.limits.contains { $0.title == "Additional" } == false)
        }
    }

    @Test func aMissingBalanceFieldIsZeroCredits() {
        let reading = CursorUnified.reading(period: nil, plan: nil, balance: Data("{}".utf8), status: nil)
        #expect(reading.credits?.caption == "$0 credits")
        #expect(CursorUnified.reading(period: nil, plan: nil, balance: nil, status: nil).credits == nil)
    }

    @Test func legacyMembershipsAreNotReadAsUnified() {
        #expect(CursorUnified.summaryIsUnified(Data(#"{"membershipType":"pro"}"#.utf8)) == false)
        #expect(CursorUnified.summaryIsUnified(Data(#"{"membershipType":"unified_ultra"}"#.utf8)) == true)
        #expect(CursorUnified.summaryIsUnified(Data(#"{"membershipType":"super"}"#.utf8)) == true)
        #expect(CursorUnified.mergedFlag(in: Data(#"{"isMerged":true}"#.utf8)) == true)
        #expect(CursorUnified.mergedFlag(in: Data(#"{"isMerged":false}"#.utf8)) == false)
        #expect(CursorUnified.mergedFlag(in: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8)) == nil)
        #expect(Credentials.membershipIsUnified("pro") == false)
        #expect(Credentials.membershipIsUnified("super") == true)
    }

    @Test func productNamesAreTheOnesTheDashboardUses() {
        #expect(CursorUnified.productTitle("cursor") == "Cursor")
        #expect(CursorUnified.productTitle("grok_bot") == "Grok Bot")
        #expect(CursorUnified.productTitle("USAGE_PRODUCT_X") == "X")
        #expect(CursorUnified.productTitle("sand") == "Grok Bot")
    }

    @Test func bearerAndCookieRequestsCarryOnlyTheSignIn() {
        let bearer = CursorAPI.bearer(CursorAPI.balanceURL, token: "tok")
        #expect(bearer.httpMethod == "POST")
        #expect(bearer.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(bearer.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(bearer.httpBody == Data("{}".utf8))
        let cookie = CursorAPI.cookie(CursorAPI.usageStatusURL, cookie: "WorkosCursorSessionToken=user%3A%3Atok")
        #expect(cookie.httpMethod == nil || cookie.httpMethod == "GET")
        #expect(cookie.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=user%3A%3Atok")
        #expect(cookie.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Suite("Cursor sign-in")
struct CursorSignInTests {
    private func jwt(exp: Double, sub: String = "auth0|user_123") -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
        let body = Data(#"{"sub":"\#(sub)","exp":\#(Int(exp))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "\(header).\(body).sig"
    }

    /// The editor can store a token that is not a JWT, beside the user id. That used to
    /// read as "not signed in" even while stripeMembershipType said Super.
    @Test func aNonJWTTokenStillMakesACookieWhenTheUserIdIsCached() {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let cookie = Credentials.cursorSessionCookie(accessToken: "opaque-token", userID: "user_9", now: now)
        #expect(cookie == "WorkosCursorSessionToken=user_9%3A%3Aopaque-token")
    }

    @Test func anExpiredTokenIsNotSent() throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let expired = jwt(exp: now.timeIntervalSince1970 - 60)
        let root = try TemporaryDirectory()
        try writeCursorDatabase(at: root.url, rows: [
            "cursorAuth/accessToken": expired,
            "cursorAuth/stripeMembershipType": "super",
            "cursorAuth/cachedUserId": "user_123",
        ])
        #expect(Credentials.cursorCredential(home: root.url, now: now) == .expired)
    }

    @Test func aSuperSeatWithALiveTokenIsSignedInAndUnified() throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let live = jwt(exp: now.timeIntervalSince1970 + 3600)
        let root = try TemporaryDirectory()
        try writeCursorDatabase(at: root.url, rows: [
            "cursorAuth/accessToken": live,
            "cursorAuth/stripeMembershipType": "super",
            "cursorAuth/cachedEmail": "you@example.com",
        ])
        guard case .signedIn(let signIn) = Credentials.cursorCredential(home: root.url, now: now) else {
            Issue.record("expected a signed-in Super seat")
            return
        }
        #expect(signIn.looksUnified)
        #expect(signIn.cookie == "WorkosCursorSessionToken=user_123%3A%3A\(live)")
        #expect(signIn.accessToken == live)
    }

    @Test func aUsableRefreshTokenStandsInWhenTheAccessTokenHasExpired() throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let expired = jwt(exp: now.timeIntervalSince1970 - 60)
        let refresh = jwt(exp: now.timeIntervalSince1970 + 3600, sub: "auth0|user_77")
        let root = try TemporaryDirectory()
        try writeCursorDatabase(at: root.url, rows: [
            "cursorAuth/accessToken": expired,
            "cursorAuth/refreshToken": refresh,
            "cursorAuth/stripeMembershipType": "unified_ultra",
        ])
        guard case .signedIn(let signIn) = Credentials.cursorCredential(home: root.url, now: now) else {
            Issue.record("expected the refresh token to be used as a bearer")
            return
        }
        #expect(signIn.accessToken == refresh)
        #expect(signIn.looksUnified)
        #expect(signIn.cookie?.contains("user_77") == true)
    }

    /// Cursor 3 writes `cursor-safe-storage:v1:` plus a Chromium v10 blob. Sending that
    /// string as a bearer is what came back as 401, "sign in again", while the plan badge
    /// still read Super from the plaintext membership.
    @Test func aSealedTokenIsNotSentUntilItIsOpened() async throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let root = try TemporaryDirectory()
        let sealed = "cursor-safe-storage:v1:djEwaTKn8QSpJ4aIH7pIsFHxMZXoxWvC8hfbRUPFq0/YaMY="
        try writeCursorDatabase(at: root.url, rows: [
            "cursorAuth/accessToken": sealed,
            "cursorAuth/stripeMembershipType": "super",
        ])
        #expect(Credentials.cursorCredential(home: root.url, now: now, readKeychain: false) == .locked)
        let report = await CursorDiagnostics.report(home: root.url, now: now, readKeychain: false)
        #expect(report.contains("sealed v1"))
        #expect(report.contains("session: sealed token was not opened"))
        #expect(!report.contains(sealed))
        #expect(report.contains("not sent") || report.contains("not asked"))
    }

    #if canImport(CommonCrypto)
    @Test func theChromiumEnvelopeOpensToTheJWT() throws {
        let stored = "cursor-safe-storage:v1:djEwaTKn8QSpJ4aIH7pIsFHxMZXoxWvC8hfbRUPFq0/YaMY="
        #expect(CursorSafeStorage.open(stored, password: Data("test-password".utf8)) == "header.payload.sig")
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let live = jwt(exp: now.timeIntervalSince1970 + 3600)
        let sealed = try #require(CursorSafeStorage.seal(live, password: Data("test-password".utf8)))
        let root = try TemporaryDirectory()
        try writeCursorDatabase(at: root.url, rows: [
            "cursorAuth/accessToken": sealed,
            "cursorAuth/stripeMembershipType": "super",
        ])
        guard case .signedIn(let signIn) = Credentials.cursorCredential(
            home: root.url, now: now, storageKey: Data("test-password".utf8), readKeychain: false
        ) else {
            Issue.record("expected the sealed token to open")
            return
        }
        #expect(signIn.accessToken == live)
        #expect(signIn.looksUnified)
        #expect(signIn.cookie == "WorkosCursorSessionToken=user_123%3A%3A\(live)")
    }
    #endif

    @Test func theWorkOSUserIdIsTheSecondSubjectSegment() {
        #expect(Credentials.userID(from: "auth0|user_123|extra") == "user_123")
        #expect(Credentials.bearerToken(from: "user_1::aaa.bbb.ccc") == "aaa.bbb.ccc")
        #expect(CursorDiagnostics.subjectHint("auth0|user_123") == "auth0|…(8)")
    }

    @Test func diagnosticsNameTheAnswerWithoutTheToken() async throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let live = jwt(exp: now.timeIntervalSince1970 + 3600)
        let root = try TemporaryDirectory()
        try writeCursorDatabase(at: root.url, rows: [
            "cursorAuth/accessToken": live,
            "cursorAuth/stripeMembershipType": "super",
            "cursorAuth/cachedEmail": "you@example.com",
        ])
        final class Stub: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var body = Data(#"{"isMerged":true,"code":"ok"}"#.utf8)
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Self.body)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let session = URLSession(configuration: configuration)
        let report = await CursorDiagnostics.report(home: root.url, now: now, session: session, readKeychain: false)
        #expect(report.contains("exp=future"))
        #expect(report.contains("sub=auth0|…(8)"))
        #expect(report.contains("cookie: built"))
        #expect(report.contains("-> 200"))
        #expect(report.contains("isMerged"))
        #expect(report.contains("cursorAuth/cachedEmail: present"))
        #expect(!report.contains(live))
        #expect(!report.contains("user_123"))
        #expect(!report.contains("you@example.com"))
    }

    private func writeCursorDatabase(at home: URL, rows: [String: String]) throws {
        let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values = rows.map { key, value in
            "('\(key.replacingOccurrences(of: "'", with: "''"))','\(value.replacingOccurrences(of: "'", with: "''"))')"
        }.joined(separator: ",")
        let sql = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable (key, value) VALUES \(values);"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

extension Credentials.CursorCredential: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.absent, .absent), (.expired, .expired), (.locked, .locked): true
        case (.signedIn(let left), .signedIn(let right)):
            left.accessToken == right.accessToken && left.cookie == right.cookie && left.membership == right.membership
        default: false
        }
    }
}
