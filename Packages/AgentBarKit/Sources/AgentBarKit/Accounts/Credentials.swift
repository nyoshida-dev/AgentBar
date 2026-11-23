import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

/// The sign-ins the agents keep on this Mac, read the way the agents' own tools read them.
/// Nothing is written back, nothing is logged, and a token lives only as long as the
/// request it is used for.
public enum Credentials {
    public struct Codex: Sendable {
        public let accessToken: String
        public let accountID: String?
        /// The person the ChatGPT sign-in was issued to, from its id token.
        public let identity: Identity
    }

    public struct Claude: Sendable {
        public let accessToken: String
        /// The plan the sign-in was issued for: "Max 20x", "Pro".
        public let plan: String?
    }

    // MARK: Claude Code

    /// Claude Code stores its OAuth tokens in the login Keychain under this service name,
    /// through the `security` tool - which macOS therefore trusts to read the item back
    /// without asking the user. Reading it through the Security framework from another
    /// app would put up a Keychain prompt; the tool does not.
    static let claudeKeychainService = "Claude Code-credentials"

    /// The sign-in Claude Code holds - the token, and the plan it was issued for. Nil
    /// when Claude Code is not signed in.
    public static func claude(home: URL = HomeDirectory.url) -> Claude? {
        if let json = keychainPassword(service: claudeKeychainService), let signIn = claude(in: json) {
            return signIn
        }
        // Older builds and Linux keep the same JSON in a file.
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")) {
            return claude(in: data)
        }
        return nil
    }

    static func claude(in data: Data) -> Claude? {
        struct File: Decodable {
            struct OAuth: Decodable {
                let accessToken: String?
                let subscriptionType: String?
                /// "default_claude_max_20x" - the multiplier a Max plan was sold with.
                let rateLimitTier: String?
            }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(File.self, from: data))?.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty else { return nil }
        return Claude(accessToken: token, plan: claudePlan(oauth.subscriptionType, tier: oauth.rateLimitTier))
    }

    /// "max" with a 20x tier is the plan a person calls "Max 20x"; the multiplier is the
    /// difference that matters, and Claude states it separately.
    static func claudePlan(_ subscription: String?, tier: String?) -> String? {
        guard let plan = Reading.planName(subscription) else { return nil }
        guard let tier, let multiplier = tier.split(separator: "_").last.map(String.init),
              multiplier.hasSuffix("x"), multiplier.dropLast().allSatisfy(\.isNumber),
              !plan.lowercased().contains(multiplier) else { return plan }
        return "\(plan) \(multiplier)"
    }

    private static func keychainPassword(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // `-w` prints the secret with a trailing newline.
        return data.last == UInt8(ascii: "\n") ? data.dropLast() : data
    }

    // MARK: Codex

    /// Codex keeps its ChatGPT sign-in in `~/.codex/auth.json`. Nil when signed in with an
    /// API key (no plan windows to show) or when the token has expired - Codex refreshes it
    /// when it runs; the app never does, so as not to touch Codex's file.
    public static func codex(home: URL = HomeDirectory.url, now: Date = .now) -> Codex? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")) else { return nil }
        return codex(in: data, now: now)
    }

    static func codex(in data: Data, now: Date) -> Codex? {
        struct File: Decodable {
            struct Tokens: Decodable {
                let access_token: String?
                let id_token: String?
                let account_id: String?
            }
            let auth_mode: String?
            let tokens: Tokens?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              file.auth_mode == nil || file.auth_mode == "chatgpt",
              let token = file.tokens?.access_token, !token.isEmpty else { return nil }
        if let expiry = JWT.expiry(of: token), expiry < now { return nil }
        // The id token is the one that names the person; the access token carries none.
        let claims = file.tokens?.id_token.flatMap { JWT.claims(of: $0) }
        return Codex(accessToken: token, accountID: file.tokens?.account_id,
                     identity: Identity(email: claims?["email"] as? String, name: claims?["name"] as? String))
    }

    // MARK: Cursor

    /// What the editor's database holds for one signed-in seat. The token is used as a
    /// bearer on Cursor's dashboard service and, when it names a user, as the session cookie
    /// the website expects. Nothing is written back, and a refresh is never asked for:
    /// trading the refresh token can invalidate the one Cursor itself keeps.
    public struct CursorSignIn: Sendable {
        public let accessToken: String
        /// Nil when the token does not name a user. Bearer calls still work without it.
        public let cookie: String?
        /// `cursorAuth/stripeMembershipType`, raw: "pro", "super", "unified_ultra".
        public let membership: String?
        public var looksUnified: Bool { Credentials.membershipIsUnified(membership) }
    }

    public enum CursorCredential: Sendable {
        /// No token in the editor's database.
        case absent
        /// A token is there and every one of them is past its `exp`.
        case expired
        /// A token is there but sealed, and the Keychain secret did not open it.
        /// The ciphertext is not sent.
        case locked
        case signedIn(CursorSignIn)
    }

    /// A merged Cursor, X and Grok seat. "super" is the SpaceXAI subscription the editor
    /// caches; "unified…" is the membership the dashboard returns for the same seat.
    static func membershipIsUnified(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return false }
        return raw == "super" || raw.hasPrefix("unified")
    }

    public static func cursorCredential(home: URL = HomeDirectory.url, now: Date = .now,
                                        storageKey: Data? = nil, readKeychain: Bool = true) -> CursorCredential {
        let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let db = SQLiteReader(reading: database) else { return .absent }
        defer { db.close() }
        let rawAccess = cleaned(db.value(in: "ItemTable", key: "cursorAuth/accessToken"))
        let rawRefresh = cleaned(db.value(in: "ItemTable", key: "cursorAuth/refreshToken"))
        let userID = cleaned(db.value(in: "ItemTable", key: "cursorAuth/cachedUserId"))
            ?? cleaned(db.value(in: "ItemTable", key: "cursorAuth/userId"))
        let membership = cleaned(db.value(in: "ItemTable", key: "cursorAuth/stripeMembershipType"))
        let stored = [rawAccess, rawRefresh].compactMap { $0 }
        guard !stored.isEmpty else { return .absent }
        let sealed = stored.contains(where: CursorSafeStorage.isSealed)
        let password = storageKey ?? (sealed && readKeychain ? CursorSafeStorage.keychainPassword(allowPrompt: true) : nil)
        let opened = stored.compactMap { CursorSafeStorage.open($0, password: password) }.map(bearerToken(from:))
        guard let token = opened.first(where: { tokenIsUsable($0, now: now) }) else {
            if sealed && opened.isEmpty { return .locked }
            return opened.isEmpty ? .absent : .expired
        }
        return .signedIn(CursorSignIn(accessToken: token,
                                      cookie: cursorSessionCookie(accessToken: token, userID: userID, now: now),
                                      membership: membership))
    }

    /// The JWT to send as a bearer. A value already shaped as `userId::jwt` contributes
    /// only the jwt; the joined form is the cookie, and the API rejects it as a bearer.
    static func bearerToken(from token: String) -> String {
        for separator in ["::", "%3A%3A"] {
            guard let range = token.range(of: separator) else { continue }
            let tail = String(token[range.upperBound...])
            if tail.split(separator: ".").count >= 3 { return tail }
        }
        return token
    }

    /// Cursor keeps its session in the editor's state database. The website wants it as a
    /// cookie: the user id (the tail of the token's subject) and the token, joined by "::".
    public static func cursorSessionCookie(home: URL = HomeDirectory.url, now: Date = .now) -> String? {
        guard case .signedIn(let signIn) = cursorCredential(home: home, now: now) else { return nil }
        return signIn.cookie
    }

    /// The account Cursor's editor has signed in, cached beside its token.
    public static func cursorIdentity(home: URL = HomeDirectory.url) -> Identity {
        let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let db = SQLiteReader(reading: database) else { return Identity() }
        defer { db.close() }
        return Identity(plan: Reading.planName(db.value(in: "ItemTable", key: "cursorAuth/stripeMembershipType")),
                        email: db.value(in: "ItemTable", key: "cursorAuth/cachedEmail"))
    }

    static func cursorSessionCookie(accessToken token: String, userID explicit: String? = nil, now: Date) -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        if let expiry = JWT.expiry(of: token), expiry < now { return nil }
        // Some builds store the cookie value itself (`user_…::jwt` or already escaped).
        if token.contains("::") || token.contains("%3A%3A") {
            let value = token.replacingOccurrences(of: "::", with: "%3A%3A")
            return "WorkosCursorSessionToken=\(value)"
        }
        let fromSubject = JWT.claims(of: token).flatMap { $0["sub"] as? String }.flatMap(userID(from:))
        guard let userID = cleaned(explicit) ?? fromSubject else { return nil }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
    }

    /// The user id is the second segment of a WorkOS subject (`auth0|user_123` →
    /// `user_123`), which is what Cursor's own dashboard cookie uses. A subject with no
    /// separator is already the id.
    static func userID(from subject: String) -> String? {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let id = parts.count > 1 ? parts[1] : parts[0]
        return id.isEmpty ? nil : String(id)
    }

    /// A token with no readable expiry is still sent: Cursor's bearer calls accept it, and
    /// treating "no exp" as signed-out was what left a live Super seat saying it was not.
    private static func tokenIsUsable(_ token: String, now: Date) -> Bool {
        guard let expiry = JWT.expiry(of: token) else { return true }
        return expiry >= now
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let stripped = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: Devin

    public struct DevinSignIn: Sendable, Equatable {
        public let apiKey: String
        public let serverURL: URL
    }

    /// The sign-in `devin auth login` left on disk, then the Devin app's own database.
    /// The first that holds a key wins. Nothing is written back.
    public static func devin(home: URL = HomeDirectory.url) -> DevinSignIn? {
        var files = [home.appendingPathComponent(".local/share/devin/credentials.toml"),
                     home.appendingPathComponent("Library/Application Support/devin/credentials.toml")]
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            files.insert(URL(fileURLWithPath: xdg).appendingPathComponent("devin/credentials.toml"), at: 0)
        }
        for file in files {
            if let text = try? String(contentsOf: file, encoding: .utf8), let signIn = devin(toml: text) {
                return signIn
            }
        }
        let database = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
        guard let db = SQLiteReader(reading: database) else { return nil }
        defer { db.close() }
        guard let json = db.value(in: "ItemTable", key: "windsurfAuthStatus"),
              let data = json.data(using: .utf8),
              let key = JSONBox.dictionary(JSONBox.object(from: data))?["apiKey"] as? String else { return nil }
        return devin(apiKey: key, server: nil)
    }

    /// `credentials.toml` as the CLI writes it: `windsurf_api_key` and an optional server.
    static func devin(toml text: String) -> DevinSignIn? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, (quote == "\"" || quote == "'"), value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            fields[String(key)] = String(value)
        }
        return devin(apiKey: fields["windsurf_api_key"] ?? "", server: fields["api_server_url"])
    }

    private static func devin(apiKey raw: String, server: String?) -> DevinSignIn? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let apiKey = key.hasPrefix(DevinAccount.sessionPrefix) || key.hasPrefix("cog_") || key.hasPrefix("apk_")
            ? key : DevinAccount.sessionPrefix + key
        let serverURL: URL
        if let parsed = server.flatMap({ URL(string: $0) }), parsed.scheme == "https" {
            serverURL = parsed
        } else {
            serverURL = DevinAccount.defaultServer
        }
        return DevinSignIn(apiKey: apiKey, serverURL: serverURL)
    }

}

/// Just enough of JSON Web Tokens to read a claim: the middle part, base64url, a JSON object.
enum JWT {
    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(of token: String) -> Date? {
        JSONBox.epoch(claims(of: token)?["exp"])
    }
}
