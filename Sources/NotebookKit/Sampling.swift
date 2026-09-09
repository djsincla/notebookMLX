import Foundation

/// How the model is asked to sample, when the reader wants a say.
///
/// Global rather than per destination, which is the rule `Endpoint` already
/// states: what differs between destinations is where an answer comes from, and
/// this is a preference about the answer itself. `maxTokens` lives the same way
/// and for the same reason.
///
/// **Every field is optional and unset means "send nothing".** That is the
/// difference between this and a struct of defaults. A notebook that shipped
/// `temperature: 0` in every request would be quietly overriding whatever the
/// endpoint chose for itself - greedy on a dAI fleet, but 0.7 on LM Studio and
/// on OpenAI - so a reader who never opened Settings would get different answers
/// than the same server gives everything else, with nothing on screen saying so.
/// Unset asks the endpoint to decide, which is what it did before this existed.
public struct Sampling: Codable, Equatable, Sendable {
    /// 0 is greedy. Higher is more varied and less repeatable.
    public var temperature: Double?
    public var topP: Double?
    /// A dAI and llama.cpp extension, not part of the OpenAI API.
    ///
    /// Sent only to a dAI fleet. OpenAI answers 400 for a body field it does
    /// not recognise, and that 400 arrives worded as a bad request with no clue
    /// which field caused it - which reads as a bad key, because that is the
    /// other thing that produces a refusal on the first question.
    public var repetitionPenalty: Double?
    /// Strings that end an answer, and are removed from it.
    public var stop: [String]

    public init(temperature: Double? = nil, topP: Double? = nil,
                repetitionPenalty: Double? = nil, stop: [String] = []) {
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.stop = stop
    }

    /// Nothing set: the endpoint's own defaults, and no sampling fields sent.
    public static let endpointDefault = Sampling()

    public var isEndpointDefault: Bool { self == .endpointDefault }

    /// The request fields, for a destination that is or is not a dAI fleet.
    ///
    /// Assembled here rather than at the call site so that there is one answer
    /// to "what does this app send", and so the rule about which fields a
    /// stranger's API will accept is written down once next to the reason.
    public func requestFields(isDaiFleet: Bool) -> [String: Any] {
        var out: [String: Any] = [:]
        if let temperature { out["temperature"] = temperature }
        if let topP { out["top_p"] = topP }
        if isDaiFleet, let repetitionPenalty {
            out["repetition_penalty"] = repetitionPenalty
        }
        if !stop.isEmpty { out["stop"] = stop }
        return out
    }

    /// Which set fields will not be sent to this destination.
    ///
    /// So Settings can say so on screen. A setting that is stored, displayed
    /// and silently ignored is worse than one that was never offered: the
    /// reader has already decided the question is answered.
    public func ignored(isDaiFleet: Bool) -> [String] {
        (!isDaiFleet && repetitionPenalty != nil) ? ["Repetition penalty"] : []
    }
}

/// Stop sequences as one line of text, and back.
///
/// A list editor for what is usually one short string would be more UI than the
/// thing deserves. Comma separated, with `\n` and `\t` written as escapes,
/// because the sequences worth setting - `\n\nHuman:`, `</task>` - are mostly
/// invisible characters and a field that cannot express them can only express
/// the ones nobody needs.
public enum StopList {
    public static func parse(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true)
            .map { unescape(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    public static func text(_ list: [String]) -> String {
        list.map(escape).joined(separator: ", ")
    }

    /// Only the two escapes worth having, and a literal backslash.
    ///
    /// Not a general unescaper. `\\u` and friends invite a field where a typo
    /// produces a different string than the one on screen, and the whole point
    /// of writing these as escapes is that what is shown is what is sent.
    static func unescape(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": out.append("\n"); i += 2; continue
                case "t": out.append("\t"); i += 2; continue
                case "\\": out.append("\\"); i += 2; continue
                default: break
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
