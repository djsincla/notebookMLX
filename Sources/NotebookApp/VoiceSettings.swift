import Foundation

/// How the app listens and speaks. Not secret, so defaults, like
/// `GatewaySettings`.
enum VoiceSettings {

    /// Which answers are read aloud, when not muted.
    ///
    /// Somebody who spoke a question is usually not looking at the screen and
    /// wants the answer spoken back; somebody who typed one is reading already,
    /// and a voice starting up unasked is an interruption. Whether anything is
    /// read at all is the speaker button's job, not this setting's: "Never" was
    /// a third option here, and a mute somebody could only reach through
    /// Settings was a mute nobody reached for mid-answer.
    enum ReadAloud: String, CaseIterable, Identifiable {
        case whenSpoken, always
        var id: String { rawValue }
        var label: String {
            switch self {
            case .whenSpoken: "When asked by voice"
            case .always: "Always"
            }
        }
    }

    static var readAloud: ReadAloud {
        get {
            UserDefaults.standard.string(forKey: "voice.readAloud")
                .flatMap(ReadAloud.init(rawValue:)) ?? .whenSpoken
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voice.readAloud") }
    }

    /// The speaker button in the Ask bar. Kept across launches: somebody who
    /// muted the app in a shared office wants it still muted tomorrow.
    ///
    /// Anybody who had chosen "Never" before the button existed starts muted,
    /// which is what that choice meant.
    static var muted: Bool {
        get {
            if let set = UserDefaults.standard.object(forKey: "voice.muted") as? Bool { return set }
            return UserDefaults.standard.string(forKey: "voice.readAloud") == "never"
        }
        set { UserDefaults.standard.set(newValue, forKey: "voice.muted") }
    }

    /// Whether holding space in an empty Ask field dictates. On by default: it
    /// only ever acts where a space would have done nothing useful.
    static var holdSpace: Bool {
        get { UserDefaults.standard.object(forKey: "voice.holdSpace") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voice.holdSpace") }
    }

    /// Whether dictation has worked on this Mac, which is what allows getting
    /// it ready in advance: by then the microphone has been allowed and the
    /// speech model is installed, so preparing asks nothing of anybody.
    static var dictationWorked: Bool {
        get { UserDefaults.standard.bool(forKey: "voice.dictationWorked") }
        set { UserDefaults.standard.set(newValue, forKey: "voice.dictationWorked") }
    }

    /// The voice answers are read in. Empty means the system's default for
    /// the current language.
    static var voiceIdentifier: String {
        get { UserDefaults.standard.string(forKey: "voice.identifier") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voice.identifier") }
    }
}
