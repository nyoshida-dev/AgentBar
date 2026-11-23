import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The quota mapping follows OpenUsage
// (https://github.com/robinebers/openusage), MIT License.
// Copyright (c) 2026 Robin Ebers
//
// Devin's CLI asks `SeatManagementService/GetUserStatus` on its configured server
// (normally server.codeium.com) with the session token `devin auth login` stored.
// The percentages are how much of each quota is *left*. The endpoint is not documented.

enum DevinAccount {
    static let defaultServer = URL(string: "https://server.codeium.com")!
    static let sessionPrefix = "devin-session-token$"
    /// The client version OpenUsage sends, which is what the service was observed to accept.
    static let cloudCompatVersion = "1.108.2"

    static func request(apiKey: String, server: URL) -> URLRequest {
        let body: [String: Any] = [
            "metadata": [
                "apiKey": apiKey,
                "ideName": "devin",
                "ideVersion": cloudCompatVersion,
                "extensionName": "devin",
                "extensionVersion": cloudCompatVersion,
                "locale": "en",
            ],
        ]
        let url = server.appendingPathComponent("exa.seat_management_pb.SeatManagementService/GetUserStatus")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("AgentBar (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        return request
    }

    /// Daily and weekly quotas as percent used, and extra usage as a dollar balance when
    /// the account reports one. A body that is not this shape is empty, so the caller can
    /// tell "not this answer" from "this account has no quota".
    static func reading(from data: Data) -> Reading {
        guard let user = JSONBox.dictionary(JSONBox.object(from: data)?["userStatus"]) else { return Reading() }
        let planStatus = JSONBox.dictionary(user["planStatus"]) ?? [:]
        let planInfo = JSONBox.dictionary(planStatus["planInfo"]) ?? [:]
        let daily = quota(planStatus, remaining: "dailyQuotaRemainingPercent", reset: "dailyQuotaResetAtUnix")
        let weekly = quota(planStatus, remaining: "weeklyQuotaRemainingPercent", reset: "weeklyQuotaResetAtUnix")
        if case .invalid = daily { return Reading() }
        if case .invalid = weekly { return Reading() }

        var limits: [UsageLimit] = []
        if JSONBox.bool(planInfo["hideDailyQuota"]) == true {
            // A plan that hides its daily quota still meters it. With no weekly window, the
            // weekly row carries that share and does not borrow the daily reset.
            switch weekly {
            case .value(let remaining, let resetsAt):
                limits.append(limit("Weekly", remaining: remaining, resetsAt: resetsAt, length: 7 * 86400))
            case .absent:
                if case .value(let remaining, _) = daily {
                    limits.append(limit("Weekly", remaining: remaining, resetsAt: nil, length: 7 * 86400))
                }
            case .invalid:
                break
            }
        } else {
            if case .value(let remaining, let resetsAt) = daily {
                limits.append(limit("Daily", remaining: remaining, resetsAt: resetsAt, length: 86400))
            }
            if case .value(let remaining, let resetsAt) = weekly {
                limits.append(limit("Weekly", remaining: remaining, resetsAt: resetsAt, length: 7 * 86400))
            }
        }
        if let micros = JSONBox.number(planStatus["overageBalanceMicros"]) {
            limits.append(UsageLimit(agent: .devin, title: "Extra usage", percentUsed: 0, resetsAt: nil,
                                     amount: max(0, micros) / 1_000_000))
        }
        let plan = Reading.planName((planInfo["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
        let email = (user["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reading(limits: limits.sortedByWindow(), identity: Identity(plan: plan, email: email?.isEmpty == true ? nil : email))
    }

    /// Devin reports the share left. Proto3 JSON omits a zero, so a window with a reset and
    /// no share has none left. A share that is present but not a number is a changed schema.
    private static func quota(_ planStatus: [String: Any], remaining key: String, reset resetKey: String) -> Quota {
        let resetsAt = JSONBox.epoch(planStatus[resetKey])
        guard let value = planStatus[key] else {
            return resetsAt.map { .value(remaining: 0, resetsAt: $0) } ?? .absent
        }
        guard let remaining = JSONBox.number(value) else { return .invalid }
        return .value(remaining: remaining, resetsAt: resetsAt)
    }

    private static func limit(_ title: String, remaining: Double, resetsAt: Date?, length: TimeInterval) -> UsageLimit {
        UsageLimit(agent: .devin, title: title, percentUsed: min(100, max(0, 100 - remaining)),
                   resetsAt: resetsAt, windowLength: length)
    }

    private enum Quota {
        case absent
        case invalid
        case value(remaining: Double, resetsAt: Date?)
    }
}
