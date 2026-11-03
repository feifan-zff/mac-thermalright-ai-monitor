// MagpieConfig.swift — Which magpie gateway to read, and with what key
//
// Gateway URL lives in UserDefaults ("magpieURL"); the API key lives in the
// login Keychain, never in the plist. Both are set from Settings → magpie.
// A remote gateway wants a magpie gateway key (sent as Authorization: Bearer);
// the local one (127.0.0.1) needs none.

import Foundation
import Security

enum MagpieConfig {

    static let defaultURL = "http://127.0.0.1:3425"

    private static let urlKey = "magpieURL"
    private static let keychainService = "com.m1ngli.MacTRAI.magpie"
    private static let keychainAccount = "apiKey"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedKey: String?
    nonisolated(unsafe) private static var _generation = 0

    /// Bumped on every change, so the collector can drop state from the old gateway.
    static var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return _generation
    }

    /// The saved address as entered; empty means the local default.
    static var savedURL: String {
        UserDefaults.standard.string(forKey: urlKey) ?? ""
    }

    static var baseURL: String {
        savedURL.isEmpty ? defaultURL : savedURL
    }

    /// Read once from the Keychain, then served from memory (the poller asks every second).
    /// MAGPIE_API_KEY overrides it for one run (CLI tests), leaving the Keychain alone.
    static var apiKey: String {
        if let k = ProcessInfo.processInfo.environment["MAGPIE_API_KEY"], !k.isEmpty { return k }
        lock.lock(); defer { lock.unlock() }
        if cachedKey == nil { cachedKey = readKeychain() ?? "" }
        return cachedKey!
    }

    struct Configuration: Sendable {
        let generation: Int
        let baseURL: String
        let apiKey: String
    }

    /// URL, key and generation must describe the same committed configuration.
    static func configuration() -> Configuration {
        lock.lock(); defer { lock.unlock() }
        if let override = ProcessInfo.processInfo.environment["MAGPIE_API_KEY"], !override.isEmpty {
            return Configuration(generation: _generation, baseURL: baseURL, apiKey: override)
        }
        if cachedKey == nil { cachedKey = readKeychain() ?? "" }
        return Configuration(generation: _generation, baseURL: baseURL, apiKey: cachedKey!)
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "钥匙串保存失败（\(status)）"
        }
    }

    static func save(url: String, apiKey key: String) throws {
        let url = normalize(url)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeKeychain(key)
        lock.lock()
        if url.isEmpty || url == defaultURL {
            UserDefaults.standard.removeObject(forKey: urlKey)
        } else {
            UserDefaults.standard.set(url, forKey: urlKey)
        }
        cachedKey = key
        _generation += 1
        lock.unlock()
        log("[Magpie] Gateway set to \(url.isEmpty ? defaultURL : url)\(key.isEmpty ? "" : " (with API key)")")
    }

    /// Trim whitespace and trailing slashes; assume http:// when no scheme is given.
    static func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty && !s.contains("://") { s = "http://" + s }
        return s
    }

    // MARK: - Keychain

    private static var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: keychainService,
         kSecAttrAccount: keychainAccount]
    }

    private static func readKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ key: String) throws {
        guard !key.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
