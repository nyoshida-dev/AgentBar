import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A read-only trace of why Cursor's account read succeeded or failed. It names keys,
/// shapes, and HTTP statuses. It does not print tokens, cookies, addresses, or ids.
public enum CursorDiagnostics {
    public static func report(home: URL = HomeDirectory.url, now: Date = .now,
                              session: URLSession = .shared, readKeychain: Bool = true,
                              storageKey: Data? = nil) async -> String {
        var lines: [String] = ["Cursor diagnostics"]
        let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let db = SQLiteReader(reading: database) else {
            lines.append("database: not opened")
            return lines.joined(separator: "\n")
        }
        defer { db.close() }
        lines.append("database: opened")

        let keys = ["cursorAuth/accessToken", "cursorAuth/refreshToken", "cursorAuth/cachedUserId",
                    "cursorAuth/userId", "cursorAuth/stripeMembershipType", "cursorAuth/cachedSignUpType",
                    "cursorAuth/cachedEmail"]
        var raw: [String: String] = [:]
        for key in keys {
            guard let value = db.value(in: "ItemTable", key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                lines.append("\(key): absent")
                continue
            }
            raw[key] = value
            lines.append("\(key): \(shape(of: value, now: now))")
        }

        let sealed = [raw["cursorAuth/accessToken"], raw["cursorAuth/refreshToken"]].compactMap { $0 }
            .contains(where: CursorSafeStorage.isSealed)
        let password: Data?
        if let storageKey {
            password = storageKey
            lines.append("keychain: supplied for this read")
        } else if !sealed {
            password = nil
            lines.append("keychain: not needed")
        } else if !readKeychain {
            password = nil
            lines.append("keychain: not asked")
        } else {
            password = CursorSafeStorage.keychainPassword(allowPrompt: true)
            if password != nil {
                lines.append("keychain \(CursorSafeStorage.keychainService): found")
            } else {
                lines.append("keychain \(CursorSafeStorage.keychainService): \(label(CursorSafeStorage.keychainState(allowPrompt: false)))")
            }
        }

        let credential = Credentials.cursorCredential(home: home, now: now, storageKey: password, readKeychain: false)
        switch credential {
        case .absent:
            lines.append("session: no usable token")
        case .expired:
            lines.append("session: token present, exp in the past")
        case .locked:
            lines.append("session: sealed token was not opened")
        case .signedIn(let signIn):
            lines.append("session: \(tokenDetail(signIn.accessToken, now: now))")
            lines.append("cookie: \(signIn.cookie == nil ? "not built" : "built")")
            lines.append(contentsOf: await probes(signIn, session: session))
        }
        return lines.joined(separator: "\n")
    }

    /// What may be said about a stored value: kind, length, and JWT claim names. Never the value.
    static func shape(of value: String, now: Date) -> String {
        if value.hasPrefix(CursorSafeStorage.prefix) {
            return "sealed v1, \(value.count) chars"
        }
        if CursorSafeStorage.isSealed(value) {
            return "sealed unknown, \(value.count) chars"
        }
        if value.contains("@") { return "present" }
        if value.count < 40, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " }) {
            return value
        }
        return tokenDetail(value, now: now)
    }

    static func tokenDetail(_ token: String, now: Date) -> String {
        let bearer = Credentials.bearerToken(from: token)
        guard let claims = JWT.claims(of: bearer) else {
            return "not a jwt, \(token.count) chars"
        }
        let names = claims.keys.sorted().joined(separator: ",")
        let exp: String
        if let expiry = JWT.expiry(of: bearer) {
            exp = expiry < now ? "past" : "future"
        } else if claims["exp"] != nil {
            exp = "unreadable"
        } else {
            exp = "missing"
        }
        let sub: String
        if let subject = claims["sub"] as? String {
            sub = subjectHint(subject)
        } else {
            sub = "absent"
        }
        return "jwt segments=\(bearer.split(separator: ".").count) claims=\(names) exp=\(exp) sub=\(sub)"
    }

    /// `auth0|user_123` becomes `auth0|…(8)`. The id itself is not included.
    static func subjectHint(_ subject: String) -> String {
        if let bar = subject.firstIndex(of: "|") {
            let scheme = subject[..<bar]
            let rest = subject[subject.index(after: bar)...].count
            return "\(scheme)|…(\(rest))"
        }
        let kind = subject.hasPrefix("user_") ? "user_" : "other"
        return "\(kind)…(\(subject.count))"
    }

    private static func label(_ state: CursorSafeStorage.Keychain) -> String {
        switch state {
        case .found: "found"
        case .notFound: "not found"
        case .needsPrompt: "needs approval"
        case .denied: "denied"
        case .unavailable: "unavailable"
        case .error(let code): "error \(code)"
        }
    }

    private static func probes(_ signIn: Credentials.CursorSignIn, session: URLSession) async -> [String] {
        let bearer = Credentials.bearerToken(from: signIn.accessToken)
        async let plan = probe("POST", CursorAPI.bearer(CursorAPI.planURL, token: bearer), session: session)
        async let period = probe("POST", CursorAPI.bearer(CursorAPI.periodURL, token: bearer), session: session)
        async let balance = probe("POST", CursorAPI.bearer(CursorAPI.balanceURL, token: bearer), session: session)
        let summary: String
        let status: String
        if let cookie = signIn.cookie {
            summary = await probe("GET", CursorAPI.cookie(CursorAPI.summaryURL, cookie: cookie), session: session)
            status = await probe("GET", CursorAPI.cookie(CursorAPI.usageStatusURL, cookie: cookie), session: session)
        } else {
            summary = "GET usage-summary: not sent (no cookie)"
            status = "GET usage-status: not sent (no cookie)"
        }
        return [await plan, await period, await balance, summary, status]
    }

    private static func probe(_ method: String, _ request: URLRequest, session: URLSession) async -> String {
        let path = request.url?.path ?? "-"
        let host = request.url?.host ?? "-"
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let finalHost = response.url?.host ?? host
            return "\(method) \(finalHost)\(path) -> \(code) \(bodySummary(data))"
        } catch {
            return "\(method) \(host)\(path) -> offline"
        }
    }

    /// Top-level keys, and a short error code when the body has one. No nested values.
    static func bodySummary(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "non-json" }
        guard let dictionary = object as? [String: Any] else {
            return object is [Any] ? "array" : "other"
        }
        let keys = dictionary.keys.sorted().joined(separator: ",")
        let code = shortCode(dictionary["code"]) ?? shortCode(dictionary["error"]) ?? shortCode(dictionary["message"])
        return code.map { "keys: \(keys); code: \($0)" } ?? "keys: \(keys)"
    }

    private static func shortCode(_ value: Any?) -> String? {
        guard let text = value as? String, (1...40).contains(text.count),
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }),
              !text.contains("@") else { return nil }
        return text
    }
}
