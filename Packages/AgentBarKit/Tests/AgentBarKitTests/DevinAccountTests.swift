import Foundation
import Testing
@testable import AgentBarKit

/// Devin's GetUserStatus shape, as OpenUsage's DevinUsageMapperTests pin it.
/// Remaining percents become percent used. Micros become dollars.
@Suite("Devin")
struct DevinAccountTests {
    private let dailyReset = Date(timeIntervalSince1970: 1_774_080_000)
    private let weeklyReset = Date(timeIntervalSince1970: 1_774_166_400)

    @Test func thePlanBothQuotasAndTheBalanceAreRead() throws {
        let reading = reading(#"""
        {"planInfo":{"planName":" Max "},
         "dailyQuotaRemainingPercent":100,"weeklyQuotaRemainingPercent":40,"overageBalanceMicros":"964220000",
         "dailyQuotaResetAtUnix":"1774080000","weeklyQuotaResetAtUnix":"1774166400"}
        """#)
        #expect(reading.identity.plan == "Max")
        #expect(reading.limits.map(\.title) == ["Daily", "Weekly", "Extra usage"])
        #expect(reading.limits[0].percentUsed == 0)
        #expect(reading.limits[0].resetsAt == dailyReset)
        #expect(reading.limits[0].windowLength == 86_400.0)
        #expect(reading.limits[1].percentUsed == 60)
        #expect(reading.limits[1].resetsAt == weeklyReset)
        #expect(reading.limits[1].windowLength == 604_800.0)
        #expect(reading.limits[2].amount == 964.22)
        #expect(reading.limits[2].amountFigure == "$964.22")
    }

    @Test func aZeroOrNegativeBalanceReadsZeroDollars() {
        for micros in [#""0""#, #""-44347""#] {
            let reading = reading(#"{"weeklyQuotaRemainingPercent":40,"overageBalanceMicros":\#(micros)}"#)
            #expect(reading.limits.last?.amount == 0)
        }
    }

    @Test func aHiddenDailyQuotaFillsTheWeeklyRowWhenThereIsNoWeeklyQuota() throws {
        let reading = reading(#"""
        {"planInfo":{"planName":"Pro","hideDailyQuota":true},"dailyQuotaRemainingPercent":30,"dailyQuotaResetAtUnix":"1774080000"}
        """#)
        #expect(reading.limits.map(\.title) == ["Weekly"])
        let weekly = try #require(reading.limits.first)
        #expect(weekly.percentUsed == 70)
        #expect(weekly.resetsAt == nil)
        #expect(weekly.windowLength == 604_800.0)
    }

    @Test func anOmittedShareBesideAResetIsUsedUp() throws {
        for hide in [true, false] {
            let reading = reading(#"""
            {"planInfo":{"planName":"Max","hideDailyQuota":\#(hide)},
             "dailyQuotaRemainingPercent":100,"dailyQuotaResetAtUnix":"1774080000","weeklyQuotaResetAtUnix":"1774166400"}
            """#)
            let weekly = try #require(reading.limits.first { $0.title == "Weekly" })
            #expect(weekly.percentUsed == 100)
            #expect(weekly.resetsAt == weeklyReset)
        }
    }

    @Test func anUnreadableShareIsNotAQuota() {
        for key in ["dailyQuotaRemainingPercent", "weeklyQuotaRemainingPercent"] {
            let reading = reading(#"""
            {"\#(key)":"abc","dailyQuotaResetAtUnix":"1774080000","weeklyQuotaResetAtUnix":"1774166400"}
            """#)
            #expect(reading.isEmpty)
        }
    }

    @Test func anAccountWithNoQuotaStillNamesItsPlan() {
        let reading = reading(#"{"planInfo":{"planName":"Max"}}"#)
        #expect(reading.limits.isEmpty)
        #expect(reading.identity.plan == "Max")
    }

    @Test func aBodyWithoutAUserStatusIsEmpty() {
        #expect(DevinAccount.reading(from: Data(#"{"code":"internal"}"#.utf8)).isEmpty)
    }

    @Test func theCLICredentialFileIsReadAndNotRewritten() throws {
        let root = try TemporaryDirectory()
        let file = root.url.appendingPathComponent(".local/share/devin/credentials.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        # written by devin auth login
        windsurf_api_key = "devin-session-token$abc"
        api_server_url = "https://server.codeium.com"
        devin_api_url = "https://api.devin.ai"
        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        let signIn = try #require(Credentials.devin(home: root.url))
        #expect(signIn.apiKey == "devin-session-token$abc")
        #expect(signIn.serverURL.absoluteString == "https://server.codeium.com")
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
    }

    @Test func aBareSessionTokenGainsThePrefixTheServiceExpects() {
        let signIn = Credentials.devin(toml: "windsurf_api_key = 'raw-token'\n")
        #expect(signIn?.apiKey == "devin-session-token$raw-token")
        #expect(signIn?.serverURL == DevinAccount.defaultServer)
        #expect(Credentials.devin(toml: "windsurf_api_key = \"cog_live\"\n")?.apiKey == "cog_live")
        #expect(Credentials.devin(toml: "api_server_url = \"https://example.com\"\n") == nil)
    }

    @Test func theRequestCarriesTheKeyAndNoOtherCredential() throws {
        let request = DevinAccount.request(apiKey: "devin-session-token$abc", server: DevinAccount.defaultServer)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(request.url?.absoluteString == "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["apiKey"] as? String == "devin-session-token$abc")
        #expect(metadata["ideName"] as? String == "devin")
    }

    private func reading(_ planStatus: String) -> Reading {
        DevinAccount.reading(from: Data(#"{"userStatus":{"planStatus":\#(planStatus)}}"#.utf8))
    }
}
