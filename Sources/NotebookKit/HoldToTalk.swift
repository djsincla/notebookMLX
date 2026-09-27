import Foundation

/// Holding space to talk, without taking space away from typing.
///
/// Space is the one key everybody already has under a thumb, and it is also a
/// character. So the first press is held back rather than acted on: released
/// quickly it was a tap, and the held-back press is replayed so the space
/// arrives as if nothing had intervened; still down after `threshold`, it was a
/// hold. Letting go stops it.
///
/// **Recording starts on the press, not on the decision.** It started once the
/// hold was certain, and a fast talker's first words went into the quarter
/// second spent deciding - measured, together with a cold start, as almost two
/// seconds of speech that never reached the recogniser. So the microphone opens
/// the moment space goes down, and a press that turns out to be a tap throws
/// away the fraction of a second it heard.
///
/// **Only where a space would be wasted.** The caller decides eligibility - in
/// this app, the Ask field focused and empty, or no text field focused at all -
/// and anywhere else space passes straight through. A hold in the middle of a
/// sentence is somebody holding the key to type spaces, however unlikely.
///
/// A pure type, events in and effects out, so the rule can be tested without a
/// keyboard, a window or a clock.
public struct HoldToTalk: Equatable, Sendable {

    /// How long space must be held before it counts as a hold. Long enough that
    /// a tap from a fast typist is never mistaken for one, short enough that a
    /// deliberate hold does not feel like waiting.
    public static let threshold: Duration = .milliseconds(250)

    public enum Event: Equatable, Sendable {
        /// Space went down. `isRepeat` is the key's autorepeat; `eligible` is
        /// whether a hold may start here at all.
        case spaceDown(isRepeat: Bool, eligible: Bool)
        case spaceUp
        /// `threshold` passed since the press being decided.
        case held
        case escape
        /// Any other key while space is down.
        case otherKey
        /// The window lost focus, or anything else that means the key-up may
        /// never arrive. A dictation left running because its release went to
        /// another app is a microphone left open.
        case interrupted
    }

    public enum Effect: Equatable, Sendable {
        /// Deliver the space press that was held back.
        case replaySpace
        /// Start the timer that will send `.held`.
        case startTimer
        /// Open the microphone. Sent on the press, before it is known whether
        /// this is a hold.
        case startRecording
        /// It is a hold: what is being recorded is meant.
        case confirmRecording
        case stopRecording
        case discardRecording
    }

    public struct Outcome: Equatable, Sendable {
        /// Whether the event is consumed here rather than passed on.
        public var consume: Bool
        public var effects: [Effect]

        public static let pass = Outcome(consume: false, effects: [])
        public static func swallow(_ effects: Effect...) -> Outcome {
            Outcome(consume: true, effects: effects)
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Space is down and it is not yet known whether it is a tap or a hold.
        case deciding
        case recording
        /// Escape threw the recording away; waiting for space to come up so its
        /// release does not type anything.
        case discarded
    }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func handle(_ event: Event) -> Outcome {
        switch (state, event) {

        case (.idle, .spaceDown(isRepeat: false, eligible: true)):
            state = .deciding
            return .swallow(.startRecording, .startTimer)
        case (.idle, _):
            return .pass

        case (.deciding, .held):
            state = .recording
            return .swallow(.confirmRecording)
        case (.deciding, .spaceDown):
            // Autorepeat while deciding. Letting it through would type the
            // spaces the hold is about to make pointless.
            return .swallow()
        case (.deciding, .spaceUp):
            state = .idle
            return .swallow(.discardRecording, .replaySpace)
        case (.deciding, .otherKey):
            // Typing fast enough that keys overlap: "a b" pressed as space-down,
            // b-down, space-up. The space was a space, it goes in first, and
            // the other key follows it through untouched.
            state = .idle
            return Outcome(consume: false, effects: [.discardRecording, .replaySpace])
        case (.deciding, .escape), (.deciding, .interrupted):
            state = .idle
            return .swallow(.discardRecording)

        case (.recording, .spaceDown):
            return .swallow()
        case (.recording, .spaceUp):
            state = .idle
            return .swallow(.stopRecording)
        case (.recording, .escape):
            state = .discarded
            return .swallow(.discardRecording)
        case (.recording, .interrupted):
            // Kept rather than discarded: what was said before the window lost
            // focus was said on purpose.
            state = .idle
            return .swallow(.stopRecording)
        case (.recording, _):
            // Other keys still work. Somebody holding space and pressing a
            // shortcut meant the shortcut.
            return .pass

        case (.discarded, .spaceDown):
            return .swallow()
        case (.discarded, .spaceUp):
            state = .idle
            return .swallow()
        case (.discarded, .interrupted):
            state = .idle
            return .swallow()
        case (.discarded, _):
            return .pass
        }
    }
}
