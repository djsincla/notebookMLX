import Foundation

/// What has been said so far, while it is still being said.
///
/// A recogniser answers twice for the same stretch of speech: a *volatile*
/// guess straight away, so the field fills while somebody is talking, and a
/// *final* reading a moment later that replaces it. Appending both produced
/// every phrase twice; keeping only finals left the field empty until a pause.
/// So finals accumulate and the one volatile guess sits on the end, replaced
/// each time a newer guess or its final arrives.
public struct LiveTranscript: Equatable, Sendable {
    public private(set) var finalized = ""
    public private(set) var volatile = ""

    public init() {}

    public mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Everything heard, finals first and the current guess after them.
    public var text: String { Self.join(finalized, volatile) }

    /// What goes in the field: anything typed before dictation started, then
    /// what was said.
    ///
    /// The typed part is kept as it was. Dictation started from the mic button
    /// with half a question already written is adding to that question, and
    /// replacing it would throw away the half somebody took the trouble to type.
    public static func compose(typed: String, spoken: String) -> String {
        join(typed, spoken)
    }

    static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}
