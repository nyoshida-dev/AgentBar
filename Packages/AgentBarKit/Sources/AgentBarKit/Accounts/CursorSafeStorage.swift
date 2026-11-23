import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if os(macOS)
import Security
#endif

/// Cursor 3 stores `cursorAuth/accessToken` sealed with Electron safeStorage. The
/// plaintext is still the JWT the dashboard accepts. The wrapping key stays in the
/// login Keychain item Cursor created (`Cursor Safe Storage` / `Cursor Key`). This
/// reads that item and decrypts in memory. It never writes the Keychain, the database,
/// or a copy of the token.
///
/// The envelope is Chromium's macOS OSCrypt v10: the bytes `v10`, then AES-128-CBC
/// with PKCS#7, a 16-space IV, and a key from PBKDF2-HMAC-SHA1 (salt `saltysalt`,
/// 1003 rounds). See Chromium `components/os_crypt/sync/os_crypt_mac.mm`.
enum CursorSafeStorage {
    static let prefix = "cursor-safe-storage:v1:"
    static let keychainService = "Cursor Safe Storage"
    static let keychainAccount = "Cursor Key"

    enum Keychain: Equatable, Sendable {
        case found
        case notFound
        case needsPrompt
        case denied
        case unavailable
        case error(Int32)
    }

    static func isSealed(_ value: String) -> Bool {
        value.hasPrefix("cursor-safe-storage:")
    }

    /// The JWT, or the stored string when it was already plaintext. Nil when the value
    /// is sealed and `password` cannot open it — the ciphertext is not a bearer.
    static func open(_ stored: String, password: Data?) -> String? {
        let stored = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        guard stored.hasPrefix(prefix) else {
            return isSealed(stored) ? nil : stored
        }
        guard let password, !password.isEmpty,
              let blob = Data(base64Encoded: String(stored.dropFirst(prefix.count)), options: .ignoreUnknownCharacters),
              let text = decrypt(blob, password: password), !text.isEmpty else { return nil }
        return text
    }

    /// One password for this process. A silent read is tried first. A prompt, when
    /// allowed, happens at most once so a denial is not asked again every refresh.
    static func keychainPassword(allowPrompt: Bool) -> Data? {
        if let cached = passwordCache.withLock({ $0.password }) { return cached }
        if passwordCache.withLock({ $0.denied }) { return nil }
        switch copyPassword(allowPrompt: false) {
        case .value(let data):
            passwordCache.withLock { $0.password = data }
            return data
        case .notFound, .unavailable:
            return nil
        case .needsPrompt, .denied, .error:
            break
        }
        guard allowPrompt else { return nil }
        switch copyPassword(allowPrompt: true) {
        case .value(let data):
            passwordCache.withLock { $0.password = data }
            return data
        case .denied, .needsPrompt:
            passwordCache.withLock { $0.denied = true }
            return nil
        case .notFound, .unavailable, .error:
            return nil
        }
    }

    static func keychainState(allowPrompt: Bool) -> Keychain {
        #if os(macOS)
        switch copyPassword(allowPrompt: allowPrompt) {
        case .value: .found
        case .notFound: .notFound
        case .needsPrompt: .needsPrompt
        case .denied: .denied
        case .unavailable: .unavailable
        case .error(let status): .error(status)
        }
        #else
        _ = allowPrompt
        return .unavailable
        #endif
    }

    #if canImport(CommonCrypto)
    /// Test helper: the same envelope Cursor writes, so a known ciphertext can be checked.
    static func seal(_ plaintext: String, password: Data) -> String? {
        guard let key = derivedKey(password), let data = plaintext.data(using: .utf8) else { return nil }
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = data.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, data.count, &output, output.count, &written)
        }
        guard status == kCCSuccess else { return nil }
        var blob = Data("v10".utf8)
        blob.append(contentsOf: output.prefix(written))
        return prefix + blob.base64EncodedString()
    }

    static func decrypt(_ encrypted: Data, password: Data) -> String? {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
              (encrypted.count - 3).isMultiple(of: kCCBlockSizeAES128),
              let key = derivedKey(password) else { return nil }
        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = ciphertext.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, ciphertext.count, &output, output.count, &written)
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: output.prefix(written), encoding: .utf8)
    }

    private static func derivedKey(_ password: Data) -> [UInt8]? {
        guard !password.isEmpty else { return nil }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: Int8.self).baseAddress,
                                 password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                 1003, &key, key.count)
        }
        return status == kCCSuccess ? key : nil
    }
    #else
    static func decrypt(_ encrypted: Data, password: Data) -> String? {
        _ = encrypted
        _ = password
        return nil
    }
    #endif

    private static let passwordCache = PasswordCache()

    private final class PasswordCache: @unchecked Sendable {
        var password: Data?
        var denied = false
        private let lock = NSLock()

        func withLock<T>(_ body: (PasswordCache) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    private enum Copy: Equatable {
        case value(Data)
        case notFound
        case needsPrompt
        case denied
        case unavailable
        case error(Int32)
    }

    private static func copyPassword(allowPrompt: Bool) -> Copy {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: allowPrompt ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return .unavailable }
            return .value(data)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .needsPrompt
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        default:
            return .error(status)
        }
        #else
        _ = allowPrompt
        return .unavailable
        #endif
    }
}
