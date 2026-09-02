import NotebookKit
import SwiftUI

/// Where the fleet is, and the key to reach it.
///
/// Three fields and a test button. The test matters more than it looks: every
/// one of these can be individually correct and collectively wrong, and finding
/// that out on the first question rather than here means blaming the notebook.
struct SettingsView: View {
    @State private var endpoints: [Endpoint]
    @State private var selectedID: UUID
    @State private var name: String
    @State private var baseURL: String
    @State private var caPath: String
    @State private var model: String
    /// nil is "work it out from the address"; a value is the operator saying.
    @State private var isDaiFleet: Bool?
    @State private var maxTokens = GatewaySettings.maxTokens
    @State private var appearance = Appearance.current
    @State private var available: [Gateway.Model] = []
    @State private var loadingModels = false
    @State private var modelsProblem: String?
    @State private var key: String
    @State private var result: String?
    @State private var testing = false
    /// Bumped on every model fetch, so a late reply for a destination that is
    /// no longer selected is dropped rather than displayed.
    @State private var generation = 0

    private let store = EndpointStore()

    init() {
        let store = EndpointStore()
        // Bring a single-destination installation forward the first time this
        // window opens, and give a fresh one something to edit rather than an
        // empty list and no obvious next move.
        store.migrateIfNeeded()
        var list = store.all
        if list.isEmpty {
            let fresh = Endpoint(name: "Fleet", baseURL: "https://localhost:8452")
            store.save(fresh)
            store.selectedID = fresh.id
            list = [fresh]
        }
        let current = store.selected ?? list[0]
        _endpoints = State(initialValue: list)
        _selectedID = State(initialValue: current.id)
        _name = State(initialValue: current.name)
        _baseURL = State(initialValue: current.baseURL)
        _caPath = State(initialValue: current.caPath)
        _model = State(initialValue: current.model)
        _isDaiFleet = State(initialValue: current.isDaiFleet)
        _key = State(initialValue: Credentials.read(current.id) ?? "")
    }

    var body: some View {
        Form {
            Section("Destination") {
                // Saved by name, because switching between a fleet, a private
                // server and somebody's cloud endpoint used to mean retyping
                // three fields and losing whichever one you were not using -
                // along with its key, which is the part that stings.
                Picker("In use", selection: inUse) {
                    ForEach(endpoints) { e in
                        Text(e.problem == nil ? e.name : "\(e.name) · \(e.problem!)")
                            .tag(e.id)
                    }
                }
                HStack(spacing: 8) {
                    Button("Add") { add() }
                    Button("Duplicate") { duplicate() }
                    Button("Delete") { remove() }
                        .disabled(endpoints.count < 2)
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Section("Where it points") {
                TextField("Name", text: $name, prompt: Text("Fleet, OpenAI, work vLLM"))
                // Declared, not guessed. The address heuristic said 127.0.0.1
                // was a fleet, which is true of the network and false of LM
                // Studio - and the consequence was waiving the model
                // requirement for a server that enforces it.
                Picker("Server", selection: $isDaiFleet) {
                    Text("Work it out").tag(Bool?.none)
                    Text("dAI fleet").tag(Bool?.some(true))
                    Text("OpenAI-compatible").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)
                TextField("Gateway", text: $baseURL, prompt: Text("https://host:8452"))
                HStack {
                    TextField("CA certificate", text: $caPath,
                              prompt: Text(destination.looksLikeFleet
                                  ? "the installer prints this path"
                                  : "leave empty - a public server uses the system roots"))
                    Button("Choose…") { choose() }
                }
                // A picker fed from the fleet, not a field to type an id into.
                //
                // The previous field required knowing an exact model id, and a
                // typo did not fail here: it failed at the next question, as a
                // refusal that reads as the fleet being broken rather than as a
                // setting being wrong.
                Picker("Model", selection: $model) {
                    Text(destination.looksLikeFleet ? "Whatever the fleet is serving"
                                                    : "Choose a model").tag("")
                    // Loaded first, then the rest. Both can be served; the
                    // ones already in memory answer immediately, and the others
                    // pay a cold load on the first question.
                    ForEach(available) { m in
                        Text(label(for: m)).tag(m.id)
                    }
                    // A model chosen earlier that the fleet is no longer
                    // serving stays selectable rather than silently reverting,
                    // which would look like the setting not saving.
                    if !model.isEmpty && !available.contains(where: { $0.id == model }) {
                        Text("\(model.split(separator: "/").last.map(String.init) ?? model) · not offered now")
                            .tag(model)
                    }
                }
                .disabled(available.isEmpty && model.isEmpty)
                HStack(spacing: 8) {
                    Button(refreshLabel) {
                        loadModels()
                    }
                    .disabled(loadingModels)
                    if let modelsProblem {
                        Text(modelsProblem).font(.caption)
                            .foregroundStyle(Palette.warning)
                    } else if !available.isEmpty {
                        Text(available.count == 1 ? "1 model offered"
                                                  : "\(available.count) models offered")
                            .font(.caption).foregroundStyle(Palette.inkSecondary)
                    }
                }
                // Said here rather than left to be inferred from a hostname.
                //
                // Pointing this at a third-party endpoint works - it is an
                // ordinary OpenAI client - and it changes the one property the
                // rest of the app is built around. Embedding stays local
                // whatever happens, so the documents never move; but the
                // question and the passages retrieved for it are the request
                // body, and they go wherever this points.
                if !destination.looksLikeFleet {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Not a dAI fleet", systemImage: "exclamationmark.triangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.warning)
                        Text("Your question and the passages retrieved for it are "
                             + "sent to this endpoint. Documents and the index stay "
                             + "on this machine either way.")
                            .font(.caption).foregroundStyle(Palette.inkSecondary)
                        if model.isEmpty {
                            Text("A model must be named: only a dAI fleet can be "
                                 + "asked without one.")
                                .font(.caption).foregroundStyle(Palette.warning)
                        }
                    }
                }
            }
            Section("Appearance") {
                // A segmented picker rather than a toggle, because there are
                // three states and "system" is not a halfway house between the
                // other two: it is a decision to keep following the machine.
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Label(option.label, systemImage: option.symbol)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, new in Appearance.current = new }
            }
            Section("Answers") {
                // A stepper rather than a text field: this is a number with a
                // sensible range and no reason to allow typing 3 into it.
                Stepper(value: $maxTokens, in: 500 ... 8000, step: 500) {
                    HStack {
                        Text("Longest answer")
                        Spacer()
                        Text("\(maxTokens) tokens")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("Where an answer is cut off if the model has not finished. "
                     + "Nothing streams here, so a longer answer is a longer "
                     + "wait rather than a longer scroll, and a model that "
                     + "finishes early costs nothing extra.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Credential") {
                // Secure, and stored in the Keychain rather than in defaults: a
                // key in a plist is readable by anything running as this user
                // and turns up in backups and screen shares.
                SecureField("API key", text: $key)
                // The advice depends on where this points. "An operator mints
                // one" is true of a fleet and nonsense for OpenAI, and a local
                // server usually wants no key at all while the app still
                // insists on something non-empty - which reads as a bug unless
                // it is said out loud.
                if destination.looksLikeFleet {
                    Text("Kept in the Keychain. An operator mints one with "
                         + "POST /admin/v1/auth/keys.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Kept in the Keychain. Use the key this provider "
                         + "issued you. A local server that ignores "
                         + "credentials still needs something here - any "
                         + "text will do.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Test Connection") { test() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result).font(.caption)
                            .foregroundStyle(result.hasPrefix("Reached") ? Palette.ok : Palette.danger)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear(perform: loadModels)
        .onDisappear(perform: save)
    }

    /// The endpoint as the fields currently stand, not as last saved.
    ///
    /// So the warning appears while somebody is typing a hostname, which is
    /// when it is worth reading, rather than after they have closed the window.
    /// An unparseable URL falls back to the local default and warns about
    /// nothing: an empty field is somebody who has not decided yet.
    /// Broken out because the ternary inline in the label defeated the type
    /// checker: "unable to type-check this expression in reasonable time".
    private var refreshLabel: String {
        if loadingModels { return "Loading…" }
        return destination.looksLikeFleet ? "Refresh from fleet" : "Refresh from server"
    }

    /// The fields on screen as an endpoint record, before they are saved.
    private var edited: Endpoint {
        Endpoint(id: selectedID, name: name, baseURL: baseURL,
                 caPath: caPath, model: model, isDaiFleet: isDaiFleet)
    }

    private var destination: Gateway.Configuration {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return Gateway.Configuration(
            baseURL: URL(string: trimmed) ?? Gateway.Configuration.localhost.baseURL,
            caCertificatePath: caPath.isEmpty ? nil : caPath)
    }

    /// How a model reads in the list.
    ///
    /// The name, then only what changes the decision: whether it will answer at
    /// once or has to be loaded, and whether asking for it engages more than one
    /// machine.
    private func label(for m: Gateway.Model) -> String {
        var out = m.shortName
        if m.machines > 1 { out += " · across \(m.machines) machines" }
        if !m.loaded { out += " · not loaded" }
        return out
    }

    /// Ask the fleet what it can serve.
    ///
    /// Failure is reported beside the control rather than thrown away: a picker
    /// that is simply empty cannot be told apart from a fleet with nothing to
    /// offer, and the two need different actions.
    /// Ask the destination on screen what it serves.
    ///
    /// Built from the fields, not from `AskBar.gateway()`. That reads the
    /// *saved* selection out of the store, and the store does not know about
    /// the switch until the next persist - so Refresh listed the destination
    /// you had just left. It showed the fleet's nine models beside a LM Studio
    /// URL, with the chosen model marked "not offered now" because the fleet
    /// has never heard of it. The same bug meant typing a new URL and pressing
    /// Refresh queried the old one.
    ///
    /// `generation` discards a reply that arrives after another switch. Without
    /// it a slow fleet answering late overwrites a fast local server's list,
    /// which looks identical to the bug above and is not the same cause.
    private func loadModels() {
        guard let configuration = edited.configuration else {
            available = []
            modelsProblem = "That is not a URL."
            return
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            available = []
            modelsProblem = "Set a key first."
            return
        }
        generation &+= 1
        let mine = generation
        loadingModels = true
        modelsProblem = nil
        let gateway = Gateway(configuration: configuration, credential: { trimmedKey })
        Task {
            defer { if mine == generation { loadingModels = false } }
            do {
                // Loaded models first: the ones that answer without a wait.
                let found = try await gateway.models()
                    .sorted { a, b in
                        a.loaded == b.loaded ? a.shortName < b.shortName : a.loaded
                    }
                guard mine == generation else { return }
                available = found
                if available.isEmpty { modelsProblem = "It offers no models." }
            } catch {
                guard mine == generation else { return }
                available = []
                modelsProblem = "\(error)"
            }
        }
    }

    /// Switching destination, as one indivisible step.
    ///
    /// This was `.onChange(of: selectedID)`, and it destroyed a saved endpoint.
    /// SwiftUI runs onChange *after* the view update, so `add()` - which sets
    /// selectedID and then loads the new endpoint's values into the fields -
    /// had already replaced them by the time the handler ran. The handler then
    /// did what it was told: saved the fields on screen into the endpoint that
    /// had just been switched away from. The result was a Fleet record
    /// containing "New destination" and "https://", and nothing anywhere said
    /// so - the only reason it was recoverable is that the migration leaves the
    /// original defaults keys in place.
    ///
    /// A binding keeps save-switch-load in one synchronous sequence with no
    /// second writer, so ordering cannot be the question.
    private var inUse: Binding<UUID> {
        Binding(get: { selectedID },
                set: { new in
                    guard new != selectedID else { return }
                    persist(into: selectedID)
                    selectedID = new
                    load(new)
                })
    }

    /// Write the fields on screen into one endpoint, and its key beside it.
    private func persist(into id: UUID) {
        var endpoint = endpoints.first(where: { $0.id == id })
            ?? Endpoint(id: id, name: name, baseURL: baseURL)
        endpoint.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.name.isEmpty { endpoint.name = "Untitled" }
        endpoint.baseURL = baseURL
        endpoint.caPath = caPath
        endpoint.model = model
        endpoint.isDaiFleet = isDaiFleet
        store.save(endpoint)
        store.selectedID = selectedID
        Credentials.write(key, for: id)
        endpoints = store.all
    }

    /// Show a different endpoint, key included.
    private func load(_ id: UUID) {
        guard let e = endpoints.first(where: { $0.id == id }) else { return }
        name = e.name
        baseURL = e.baseURL
        caPath = e.caPath
        model = e.model
        isDaiFleet = e.isDaiFleet
        key = Credentials.read(id) ?? ""
        // The model list belongs to the endpoint that offered it.
        available = []
        modelsProblem = nil
        result = nil
        loadModels()
    }

    private func add() {
        persist(into: selectedID)
        let fresh = Endpoint(name: "New destination", baseURL: "https://")
        store.save(fresh)
        endpoints = store.all
        selectedID = fresh.id
        load(fresh.id)
    }

    private func duplicate() {
        persist(into: selectedID)
        // A new id, so it gets its own Keychain item rather than sharing one.
        // The key is not copied: the common reason to duplicate is the same
        // server with different credentials, and silently carrying one over
        // would be the wrong guess in the case that matters.
        let copy = Endpoint(name: "\(name) copy", baseURL: baseURL,
                            caPath: caPath, model: model, isDaiFleet: isDaiFleet)
        store.save(copy)
        endpoints = store.all
        selectedID = copy.id
        load(copy.id)
    }

    private func remove() {
        guard endpoints.count > 1 else { return }
        let doomed = selectedID
        // The key goes with it. A credential outliving the destination it was
        // for is a secret nobody is looking after any more.
        Credentials.delete(doomed)
        store.remove(doomed)
        endpoints = store.all
        if let next = store.selected?.id {
            selectedID = next
            load(next)
        }
    }

    private func save() {
        GatewaySettings.maxTokens = maxTokens
        persist(into: selectedID)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the control plane's CA certificate"
        if panel.runModal() == .OK, let url = panel.url { caPath = url.path }
    }

    private func test() {
        save()
        testing = true
        result = nil
        Task {
            guard let url = URL(string: baseURL) else {
                result = "That is not a URL."; testing = false; return
            }
            let id = selectedID
            let gateway = Gateway(
                configuration: .init(baseURL: url,
                                     caCertificatePath: caPath.isEmpty ? nil : caPath),
                credential: { Credentials.read(id) })
            do {
                // A real request rather than a ping, because reachability and
                // a working credential are different questions and only the
                // second one matters here.
                let answer = try await gateway.answer(
                    question: "Reply with the single word: ready.",
                    passages: [], history: [],
                    model: model.isEmpty ? nil : model, maxTokens: 16)
                result = "Reached \(answer.node ?? "the fleet")"
                    + (answer.model.map { " · \($0)" } ?? "")
            } catch {
                result = "\(error)"
            }
            testing = false
        }
    }
}
