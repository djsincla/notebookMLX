import AVFoundation
import NotebookKit
import Observation

/// Answers, spoken.
///
/// One for the whole app rather than one per window: two windows answering at
/// once should not talk over each other, and a new answer anywhere is the one
/// somebody is waiting to hear.
///
/// On-device. AVSpeechSynthesizer uses the voices installed on this Mac, so an
/// answer that never left the building is not sent anywhere to be read out.
@Observable @MainActor
final class ReadAloud {
    static let shared = ReadAloud()

    private(set) var speaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let watcher = Watcher()

    private init() {
        synthesizer.delegate = watcher
        watcher.changed = { [weak self] speaking in
            Task { @MainActor in self?.speaking = speaking }
        }
    }

    /// Read a turn's answer, citations and markdown removed.
    func speak(_ turn: NotebookPackage.Turn) {
        let text = SpeakableText.from(answer: turn.answer,
                                      citations: turn.citations.map(\.citation))
        guard !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if let voice = Self.chosenVoice() { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The voice from Settings, or nil for the system default.
    ///
    /// A voice that has since been removed from the Mac falls back rather than
    /// failing: an answer read in the default voice is better than one not read.
    static func chosenVoice() -> AVSpeechSynthesisVoice? {
        let id = VoiceSettings.voiceIdentifier
        guard !id.isEmpty else { return nil }
        return AVSpeechSynthesisVoice(identifier: id)
    }

    /// Voices for the current language, best first.
    ///
    /// The language filter is what makes the list usable: a Mac carries dozens
    /// of voices, and an English answer read in a Korean voice is not a choice
    /// anybody means to make.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name < $1.name
            }
    }

    static func label(for voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: " · Premium"
        case .enhanced: " · Enhanced"
        default: ""
        }
        return "\(voice.name) (\(voice.language))\(quality)"
    }

    /// The delegate, kept apart because its callbacks arrive off the main actor.
    private final class Watcher: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        var changed: (@Sendable (Bool) -> Void)?
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
            changed?(true)
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
            changed?(false)
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
            changed?(false)
        }
    }
}
