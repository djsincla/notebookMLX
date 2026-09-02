import Foundation

/// A place this notebook can send a question, saved by name.
///
/// There was one, and it was three loose defaults keys. That is right while the
/// answer is always "the fleet downstairs", and wrong the moment it is not: a
/// private vLLM at work, somebody's OpenAI key for a comparison, a fleet at
/// another site. Retyping a URL, a certificate path and a model to switch
/// between them loses whichever one you were not using, and the key with it.
///
/// So each destination is a record and the app holds a list. Everything that
/// differs between destinations lives here; `maxTokens` and the like stay
/// global, because they are preferences about answers rather than about where
/// answers come from.
///
/// The API key does **not** live here. It goes in the Keychain, one item per
/// endpoint id, for the reasons `Credentials` gives - and because a list of
/// endpoints is the sort of thing somebody exports to move to a new machine.
public struct Endpoint: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// What the operator calls it. Never sent anywhere.
    public var name: String
    public var baseURL: String
    /// A private authority to trust instead of the system store. Empty means
    /// the system roots, which is what any public endpoint needs.
    public var caPath: String
    /// Empty asks the endpoint to choose, which only a dAI fleet can do.
    public var model: String
    /// Whether this is a dAI fleet. nil means infer from the address.
    ///
    /// The inference is only ever a guess and it was wrong where it counted:
    /// LM Studio on 127.0.0.1 is a private address and not a fleet, so the
    /// model requirement got waived for a server that enforces it. Optional,
    /// not a plain Bool, so records written before this decode as "infer" and
    /// keep behaving as they did.
    public var isDaiFleet: Bool?

    public init(id: UUID = UUID(), name: String, baseURL: String,
                caPath: String = "", model: String = "",
                isDaiFleet: Bool? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.caPath = caPath
        self.model = model
        self.isDaiFleet = isDaiFleet
    }

    /// The gateway configuration this describes, or nil if the URL is unusable.
    public var configuration: Gateway.Configuration? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.host != nil else {
            return nil
        }
        return Gateway.Configuration(baseURL: url,
                                     caCertificatePath: caPath.isEmpty ? nil : caPath,
                                     isDaiFleet: isDaiFleet)
    }

    /// Whether this destination can be asked at all as it stands.
    ///
    /// Separate from whether it will answer. A model is required off-fleet, and
    /// saying so in the list is better than letting somebody select a broken
    /// destination and find out at the next question.
    public var problem: String? {
        guard let configuration else { return "needs a valid URL" }
        if !configuration.looksLikeFleet && model.isEmpty {
            return "needs a model"
        }
        return nil
    }
}

/// The saved destinations and which one is in use.
///
/// Backed by `UserDefaults`, injectable so the migration can be tested against
/// a scratch domain rather than the developer's own settings - which is how a
/// previous test in this project came to be reading the machine it ran on.
/// Not `Sendable`, because `UserDefaults` is not. It is thread safe in
/// practice - the compiler objects to the shared mutable reference rather than
/// to the access - and this is only ever touched from the main actor, so
/// claiming otherwise would be a promise nothing checks.
public struct EndpointStore {
    public static let listKey = "gateway.endpoints"
    public static let selectedKey = "gateway.selectedEndpoint"

    /// The single-destination keys this replaces. Read once, at migration.
    static let legacyURL = "gateway.baseURL"
    static let legacyCA = "gateway.ca"
    static let legacyModel = "gateway.model"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var all: [Endpoint] {
        get {
            guard let data = defaults.data(forKey: Self.listKey),
                  let list = try? JSONDecoder().decode([Endpoint].self, from: data)
            else { return [] }
            return list
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.listKey)
        }
    }

    public var selectedID: UUID? {
        get {
            guard let raw = defaults.string(forKey: Self.selectedKey) else { return nil }
            return UUID(uuidString: raw)
        }
        nonmutating set {
            defaults.set(newValue?.uuidString, forKey: Self.selectedKey)
        }
    }

    /// The destination in use, falling back to the first saved one.
    ///
    /// A dangling selection - the selected endpoint deleted on another machine,
    /// or the list edited by hand - resolves to the first rather than to
    /// nothing, because a notebook that silently stops answering is worse than
    /// one that answers from the wrong place and says which.
    public var selected: Endpoint? {
        let list = all
        if let id = selectedID, let match = list.first(where: { $0.id == id }) {
            return match
        }
        return list.first
    }

    public func save(_ endpoint: Endpoint) {
        var list = all
        if let i = list.firstIndex(where: { $0.id == endpoint.id }) {
            list[i] = endpoint
        } else {
            list.append(endpoint)
        }
        all = list
    }

    /// Removes one, and hands back its id so the caller can forget its key.
    ///
    /// The Keychain is not touched here: this type is in NotebookKit and has no
    /// business holding credentials. Leaving the item behind on delete would be
    /// a secret outliving the thing it was for, so the caller must do it, and
    /// the return value is the reminder.
    @discardableResult
    public func remove(_ id: UUID) -> UUID {
        all = all.filter { $0.id != id }
        if selectedID == id { selectedID = all.first?.id }
        return id
    }

    /// Bring a single-destination installation forward, once.
    ///
    /// Runs when the list is empty and the old keys are present. The endpoint
    /// keeps a **stable, derived id** rather than a fresh one, so the Keychain
    /// item saved against it can be found again by a caller that computes the
    /// same id - the alternative is a migration that silently loses the key and
    /// presents an endpoint that cannot authenticate.
    ///
    /// The legacy keys are left in place. They cost nothing, and a migration
    /// that deletes its own source cannot be run again after a bug is found.
    @discardableResult
    public func migrateIfNeeded() -> Endpoint? {
        guard all.isEmpty else { return nil }
        let url = defaults.string(forKey: Self.legacyURL) ?? ""
        let ca = defaults.string(forKey: Self.legacyCA) ?? ""
        let model = defaults.string(forKey: Self.legacyModel) ?? ""
        guard !url.isEmpty || !ca.isEmpty || !model.isEmpty else { return nil }

        let migrated = Endpoint(id: Self.migratedID, name: "Fleet",
                                baseURL: url.isEmpty ? "https://localhost:8452" : url,
                                caPath: ca, model: model)
        all = [migrated]
        selectedID = migrated.id
        return migrated
    }

    /// Fixed so the migrated endpoint's Keychain item can be located without
    /// having to have been recorded anywhere.
    public static let migratedID = UUID(uuidString: "00000000-0000-0000-0000-00000da10001")!
}
