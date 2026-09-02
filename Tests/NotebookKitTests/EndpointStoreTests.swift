import Foundation
import Testing
@testable import NotebookKit

/// Saved destinations, and bringing a single-destination installation forward.
///
/// Against a scratch `UserDefaults` suite, never `.standard`. A test that wrote
/// to the real domain would rewrite the developer's own settings while it ran,
/// which is the mistake this project has already made once today in the backup
/// suite - and there it was writing to a live certificate authority.
struct EndpointStoreTests {
    /// A fresh domain per test, removed afterwards.
    private func scratch(_ body: (EndpointStore) throws -> Void) rethrows {
        let name = "notebookmlx.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(EndpointStore(defaults: defaults))
    }

    @Test("saves, lists and selects")
    func basics() {
        scratch { store in
            let a = Endpoint(name: "Fleet", baseURL: "https://localhost:8452")
            let b = Endpoint(name: "OpenAI", baseURL: "https://api.openai.com",
                             model: "gpt-4o-mini")
            store.save(a)
            store.save(b)
            #expect(store.all.count == 2)
            // Nothing selected yet resolves to the first, rather than to
            // nothing: a notebook that silently stops answering is worse than
            // one that answers and says from where.
            #expect(store.selected?.id == a.id)
            store.selectedID = b.id
            #expect(store.selected?.name == "OpenAI")
        }
    }

    @Test("editing replaces rather than appends")
    func editInPlace() {
        scratch { store in
            var e = Endpoint(name: "Fleet", baseURL: "https://localhost:8452")
            store.save(e)
            e.name = "Home fleet"
            store.save(e)
            #expect(store.all.count == 1)
            #expect(store.all.first?.name == "Home fleet")
        }
    }

    @Test("a dangling selection falls back rather than answering nothing")
    func danglingSelection() {
        scratch { store in
            let a = Endpoint(name: "Fleet", baseURL: "https://localhost:8452")
            store.save(a)
            store.selectedID = UUID()   // deleted elsewhere, or hand-edited
            #expect(store.selected?.id == a.id)
        }
    }

    @Test("removing clears the selection with it")
    func removal() {
        scratch { store in
            let a = Endpoint(name: "A", baseURL: "https://localhost:8452")
            let b = Endpoint(name: "B", baseURL: "https://10.0.0.5:8452")
            store.save(a); store.save(b)
            store.selectedID = b.id
            store.remove(b.id)
            #expect(store.all.count == 1)
            #expect(store.selectedID == a.id)
        }
    }

    @Test("brings a single-destination installation forward once")
    func migrates() {
        let name = "notebookmlx.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("https://rotorua.local:8452", forKey: EndpointStore.legacyURL)
        defaults.set("/etc/dai/srv-ca.crt", forKey: EndpointStore.legacyCA)
        defaults.set("mlx-community/Qwen2.5-14B-Instruct-4bit", forKey: EndpointStore.legacyModel)

        let store = EndpointStore(defaults: defaults)
        let migrated = store.migrateIfNeeded()
        #expect(migrated?.baseURL == "https://rotorua.local:8452")
        #expect(migrated?.caPath == "/etc/dai/srv-ca.crt")
        #expect(migrated?.model == "mlx-community/Qwen2.5-14B-Instruct-4bit")
        #expect(store.selected?.id == EndpointStore.migratedID)

        // The id is fixed, not fresh. The Keychain item predating endpoints is
        // filed under the old account name, and only a known id lets the app
        // find it again - a fresh UUID would lose the key and present an
        // endpoint that cannot authenticate.
        #expect(migrated?.id == EndpointStore.migratedID)

        // Idempotent: running again must not add a second copy.
        #expect(store.migrateIfNeeded() == nil)
        #expect(store.all.count == 1)

        // And the source keys survive, so a migration found to be wrong can be
        // corrected and re-run.
        #expect(defaults.string(forKey: EndpointStore.legacyURL) != nil)
    }

    @Test("a fresh installation has nothing to migrate")
    func nothingToMigrate() {
        scratch { store in
            #expect(store.migrateIfNeeded() == nil)
            #expect(store.all.isEmpty)
        }
    }

    @Test("says what is wrong with a destination before it is selected")
    func problems() {
        // Off-fleet without a model is the mistake worth catching in the list,
        // because the alternative is a 400 at the next question that reads as
        // a bad key.
        #expect(Endpoint(name: "OpenAI", baseURL: "https://api.openai.com").problem
                == "needs a model")
        #expect(Endpoint(name: "OpenAI", baseURL: "https://api.openai.com",
                         model: "gpt-4o-mini").problem == nil)
        // A fleet may be asked without one.
        #expect(Endpoint(name: "Fleet", baseURL: "https://localhost:8452").problem == nil)
        #expect(Endpoint(name: "Broken", baseURL: "not a url").problem == "needs a valid URL")
        #expect(Endpoint(name: "Empty", baseURL: "").problem == "needs a valid URL")
    }
}
