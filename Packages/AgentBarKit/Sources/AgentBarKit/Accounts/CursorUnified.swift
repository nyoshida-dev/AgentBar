import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The unified-account mapping follows OpenUsage
// (https://github.com/robinebers/openusage), MIT License.
// Copyright (c) 2026 Robin Ebers
//
// A merged Cursor, X and Grok account has one weekly included pool. Cursor's older
// usage-summary answer still describes a monthly plan, which is why a Super seat showed
// a plan badge and then nothing useful. The figures below are the ones Cursor's own
// dashboard reads: GetPlanInfo, GetCurrentPeriodUsage, GetComplatCreditBalance, and
// `cursor.com/api/dashboard/v2/usage-status`. None of those endpoints is documented.

enum CursorAPI {
    static let periodURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    static let balanceURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetComplatCreditBalance")!
    static let usageStatusURL = URL(string: "https://cursor.com/api/dashboard/v2/usage-status?scope=user")!
    static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    static func bearer(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("AgentBar (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 10
        return request
    }

    static func cookie(_ url: URL, cookie: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("AgentBar (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }
}

enum CursorUnified {
    /// `GetPlanInfo.isMerged`, when the field is present. Nil when this answer does not say.
    static func mergedFlag(in data: Data) -> Bool? {
        guard let object = JSONBox.object(from: data), object["isMerged"] != nil else { return nil }
        return JSONBox.bool(object["isMerged"]) == true
    }

    /// The usage-summary membership of a merged seat: `super`, `unified_ultra`, and the like.
    static func summaryIsUnified(_ data: Data) -> Bool {
        guard let type = JSONBox.object(from: data)?["membershipType"] as? String else { return false }
        return Credentials.membershipIsUnified(type)
    }

    /// Weekly pool, each product's share of it, additional usage, and the credit balance.
    /// An answer that failed to arrive is nil and simply leaves its rows out.
    static func reading(period: Data?, plan: Data?, balance: Data?, status: Data?) -> Reading {
        let periodObject = period.flatMap(JSONBox.object(from:))
        let planObject = plan.flatMap(JSONBox.object(from:))
        let statusObject = status.flatMap(JSONBox.object(from:))
        let planInfo = JSONBox.dictionary(planObject?["planInfo"])
        let name = (planInfo?["planName"] as? String) ?? (planObject?["planName"] as? String)
        let cycle = window(period: periodObject, planInfo: planInfo, status: statusObject)

        var limits: [UsageLimit] = []
        if let weekly = weeklyLimit(period: periodObject, status: statusObject, cycle: cycle) {
            limits.append(weekly)
            limits += productLimits(status: statusObject, like: weekly)
        } else {
            limits += productLimits(status: statusObject, like: nil)
        }
        if let additional = additionalLimit(status: statusObject) { limits.append(additional) }

        return Reading(limits: limits.sortedByWindow(), credits: creditBalance(in: balance),
                       identity: Identity(plan: planLabel(name)))
    }

    // MARK: Weekly pool

    private struct Window {
        var end: Date?
        var length: TimeInterval?
    }

    private static func weeklyLimit(period: [String: Any]?, status: [String: Any]?, cycle: Window) -> UsageLimit? {
        let planUsage = JSONBox.dictionary(period?["planUsage"])
        if let percent = JSONBox.number(planUsage?["totalPercentUsed"]), percent >= 0 {
            return UsageLimit(agent: .cursor, title: "Weekly", percentUsed: percent,
                              resetsAt: cycle.end, windowLength: cycle.length ?? 7 * 86400,
                              fullName: "shared by Cursor, X and Grok")
        }
        guard let weekly = JSONBox.dictionary(status?["weeklyIncludedUsage"]),
              let used = JSONBox.number(weekly["usedCents"]),
              let budget = JSONBox.number(weekly["budgetCents"]), budget > 0 else { return nil }
        let end = ISODate.parse(weekly["resetsAt"] as? String) ?? cycle.end
        let start = ISODate.parse(weekly["periodStart"] as? String)
        let length = zip(start, end).map { $1.timeIntervalSince($0) }.flatMap { $0 > 0 ? $0 : nil } ?? cycle.length
        return UsageLimit(agent: .cursor, title: "Weekly", percentUsed: max(0, used) / budget * 100,
                          resetsAt: end, windowLength: length ?? 7 * 86400,
                          fullName: "shared by Cursor, X and Grok")
    }

    /// Each product's cents as a percent of the same weekly budget. "Cursor 15%" is 15% of
    /// the pool, not a second allowance.
    private static func productLimits(status: [String: Any]?, like weekly: UsageLimit?) -> [UsageLimit] {
        guard let status,
              let included = JSONBox.dictionary(status["weeklyIncludedUsage"]),
              let budget = JSONBox.number(included["budgetCents"]), budget > 0,
              let rows = status["weeklyIncludedUsageByProduct"] as? [Any] else { return [] }
        let end = weekly?.resetsAt ?? ISODate.parse(included["resetsAt"] as? String)
        let length = weekly?.windowLength
        var seen: [String: Int] = [:]
        return rows.compactMap { row in
            guard let row = row as? [String: Any],
                  let cents = JSONBox.number(row["cents"]),
                  let raw = (row["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            var title = productTitle(raw)
            seen[title, default: 0] += 1
            if seen[title, default: 0] > 1 { title = "\(title) \(seen[title]!)" }
            return UsageLimit(agent: .cursor, title: title, percentUsed: max(0, cents) / budget * 100,
                              resetsAt: end, windowLength: length, fullName: "share of the weekly pool")
        }
    }

    static func productTitle(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = key.lowercased()
        for prefix in ["usage_product_", "product_"] where lowered.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
            break
        }
        switch key.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "cursor", "cursor_ide", "cursor_agent": return "Cursor"
        case "grok", "grok_bot", "grokbot", "sand": return "Grok Bot"
        case "x", "twitter": return "X"
        default:
            return key.split { $0 == "_" || $0 == "-" || $0 == " " }
                .map { word in
                    guard let first = word.first else { return "" }
                    return first.uppercased() + word.dropFirst().lowercased()
                }
                .joined(separator: " ")
        }
    }

    // MARK: Additional usage and credits

    /// The dashboard's Additional usage card. Off, or a $0 cap, hides it. With no cap the
    /// row is the amount spent this month, including $0, paid from the credit balance.
    private static func additionalLimit(status: [String: Any]?) -> UsageLimit? {
        guard let status, (status["availability"] as? String ?? "available") == "available",
              let monthly = JSONBox.dictionary(status["monthlyUsage"]),
              JSONBox.bool(monthly["additionalUsageOff"]) != true else { return nil }
        let limitCents = JSONBox.number(monthly["limitCents"])
        if limitCents == 0 { return nil }
        let usedCents = max(0, JSONBox.number(monthly["usedCents"]) ?? 0)
        let end = ISODate.parse(monthly["resetsAt"] as? String)
        let start = ISODate.parse(monthly["periodStart"] as? String)
        let length = zip(start, end).map { $1.timeIntervalSince($0) }.flatMap { $0 > 0 ? $0 : nil }
        if let limitCents, limitCents > 0 {
            return UsageLimit(agent: .cursor, title: "Additional", percentUsed: usedCents / limitCents * 100,
                              resetsAt: end, windowLength: length)
        }
        return UsageLimit(agent: .cursor, title: "Additional", percentUsed: 0, resetsAt: nil, amount: usedCents / 100)
    }

    /// `usdRemainingCents` is the dashboard's Credits card. A successful answer that leaves
    /// the field out is a balance of zero, which the card still shows.
    private static func creditBalance(in data: Data?) -> Credits? {
        guard let data, let object = JSONBox.object(from: data) else { return nil }
        let cents = max(0, JSONBox.number(object["usdRemainingCents"]) ?? 0)
        return Credits(balance: cents / 100, showsZero: true)
    }

    private static func window(period: [String: Any]?, planInfo: [String: Any]?, status: [String: Any]?) -> Window {
        let start = JSONBox.epoch(period?["billingCycleStart"])
        let end = JSONBox.epoch(period?["billingCycleEnd"])
            ?? JSONBox.epoch(planInfo?["includedUsageResetsAt"])
            ?? status.flatMap { ISODate.parse(JSONBox.dictionary($0["weeklyIncludedUsage"])?["resetsAt"] as? String) }
        let length = zip(start, end).map { $1.timeIntervalSince($0) }.flatMap { $0 > 0 ? $0 : nil }
        let weekly = (planInfo?["includedUsagePeriod"] as? String) == "INCLUDED_USAGE_PERIOD_WEEKLY"
        return Window(end: end, length: length ?? (weekly ? 7 * 86400 : nil))
    }

    /// "unified_ultra" is the seat, "Ultra" is the plan a person says. A name the plan
    /// info already wrote in words is only tidied.
    private static func planLabel(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return nil }
        if text.hasPrefix("unified_") { text = String(text.dropFirst("unified_".count)) }
        return Reading.planName(text)
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
