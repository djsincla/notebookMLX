import Foundation
import NotebookKit
import Security

/// The gateway key, in the Keychain.
///
/// Not UserDefaults. A key in a plist is world readable by anything running as
/// this user, survives in Time Machine backups, and turns up in a screen share
/// when somebody opens the file. The Keychain is what the platform provides for
/// exactly this and costs about forty lines.
///
/// `kSecAttrAccessibleWhenUnlocked` rather than the default: the app has no
/// reason to read the key while the machine is locked, and a key that cannot be
/// read then cannot be taken from a sleeping laptop.
/// One item per endpoint, since each destination has its own key.
///
/// The account is the endpoint's id. That is why `EndpointStore.migratedID` is
/// a fixed value rather than a fresh UUID: the key saved before endpoints
/// existed lives under the old account name, and the migration has to be able
/// to find it again from nothing but the id it invented.
enum Credentials {
    private static let service = "com.dai.notebookmlx.gateway"
    /// What the single-destination version used. Read for migration, then left
    /// alone - deleting it would make the migration unrepeatable if it is wrong.
    private static let legacyAccount = "api-key"

    private static func account(_ id: UUID) -> String { id.uuidString }

    static func read(_ id: UUID) -> String? {
        if let found = read(account: account(id)) { return found }
        // The migrated endpoint inherits the key that predates endpoints. Only
        // that id, so a second endpoint does not silently borrow it.
        if id == EndpointStore.migratedID { return read(account: legacyAccount) }
        return nil
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func write(_ key: String, for id: UUID) -> Bool {
        let account = account(id)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete(id) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        // Update first, add if absent. Adding over an existing item fails with
        // errSecDuplicateItem rather than replacing it.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        return SecItemAdd(query.merging(attributes) { a, _ in a } as CFDictionary,
                          nil) == errSecSuccess
    }

    /// Forgets an endpoint's key. Called when the endpoint is deleted, so a
    /// credential does not outlive the thing it was for.
    @discardableResult
    static func delete(_ id: UUID) -> Bool {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(id),
        ] as CFDictionary) == errSecSuccess
    }
}

/// Where the fleet is, which is not a secret and lives in defaults.
///
/// Deliberately separate from the key above. The address of a machine is not a
/// credential and putting it in the Keychain would mean a prompt to read
/// something nobody needs protected.
enum GatewaySettings {
    // UserDefaults.standard is not Sendable, so it is reached for at each use
    // rather than held in a static. It is thread safe in practice; the compiler
    // is objecting to the shared mutable reference, not to the access.
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "gateway.baseURL")
              ?? "https://localhost:8452" }
        set { UserDefaults.standard.set(newValue, forKey: "gateway.baseURL") }
    }

    /// The control plane's CA, which the installer prints. Empty means the
    /// system trust store decides, which for a self signed fleet means the
    /// connection is refused rather than silently accepted.
    static var caPath: String {
        get { UserDefaults.standard.string(forKey: "gateway.ca") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "gateway.ca") }
    }

    /// Empty lets the gateway choose, which is right when one model is served.
    static var model: String {
        get { UserDefaults.standard.string(forKey: "gateway.model") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "gateway.model") }
    }

    /// The longest answer the fleet is asked for, in tokens.
    ///
    /// **This is a ceiling, not a target**: the model stops when it has finished
    /// and the limit only decides where it is cut off if it has not. It was 800
    /// and not adjustable, which is roughly 600 words, and a long answer from a
    /// technical manual reached it and stopped mid sentence. A truncated answer
    /// is worse than a short one, because it looks like the model had nothing
    /// further to say.
    ///
    /// The cost of raising it is waiting: nothing streams here, a completion is
    /// dispatched to a node as one unit, so a longer answer is a longer silence
    /// rather than a longer scroll. 2,000 tokens is about 1,500 words, which
    /// covers a procedure with its caveats without making a one line answer
    /// slower, since a model that finishes early is not charged for the rest.
    static let defaultMaxTokens = 2000

    static var maxTokens: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "gateway.maxTokens")
            // `integer(forKey:)` returns 0 for a key that was never set, which
            // is indistinguishable from a stored 0 and would ask for an empty
            // answer. Anything unset or nonsensical falls back.
            return stored >= 256 ? min(stored, 32000) : defaultMaxTokens
        }
        set { UserDefaults.standard.set(newValue, forKey: "gateway.maxTokens") }
    }
}
