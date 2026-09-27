import Foundation

/// How the app listens and speaks. Not secret, so defaults, like
/// `GatewaySettings`.
enum VoiceSettings {

    /// When an answer is read aloud.
    ///
    /// Three states rather than a switch, because the useful default is neither
    /// on nor off. Somebody who spoke a question is usually not looking at the
    /// screen and wants the answer spoken back; somebody who typed one is
    /// reading already, and a voice starting up unasked is an interruption.
    enum ReadAloud: String, CaseIterable, Identifiable {
        case never, whenSpoken, always
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: "Never"
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
