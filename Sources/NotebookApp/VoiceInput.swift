import AppKit
import NotebookKit
import Observation
import SwiftUI

/// Hold space, or click the mic, to put a spoken question in the Ask field.
///
/// Dictate-then-review: speech fills the field and Return sends it, so a
/// misheard product name is fixed before it reaches the fleet rather than
/// answered. `HoldToTalk` decides what each press of space means; this is the
/// part that listens to the keyboard, owns the microphone and writes the field.
@available(macOS 26, *)
@Observable @MainActor
final class Talker {

    /// What the Ask bar lends this: its field, its focus and whether asking is
    /// possible right now.
    struct Host {
        var text: Binding<String>
        var fieldFocused: () -> Bool
        var focusField: () -> Void
        var enabled: () -> Bool
        var vocabulary: () -> [String]
        /// Told when a dictation put words in the field, so the answer to that
        /// question can be read back.
        var dictated: () -> Void
    }

    let dictation = Dictation()
    /// Whether the current dictation is a held space, which changes what the
    /// status line tells somebody to do to stop it.
    private(set) var byHold = false
    /// What was in the field when dictation started, kept so speech is added
    /// to it and so Escape can put it back.
    private(set) var typed = ""

    @ObservationIgnored var host: Host?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var machine = HoldToTalk()
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resigned: NSObjectProtocol?
    @ObservationIgnored private var heldDown: NSEvent?
    @ObservationIgnored private var timer = 0
    @ObservationIgnored private var replaying = false

    // ------------------------------------------------------------ keyboard

    func install() {
        guard monitor == nil else { return }
        // AppKit calls this on the main thread without saying so in its type.
        // Only a Bool crosses back out, because NSEvent is not Sendable.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            nonisolated(unsafe) let seen = event
            let keep = MainActor.assumeIsolated { self?.keeps(seen) ?? true }
            return keep ? event : nil
        }
        // A release that lands in another app never arrives here. Without this,
        // switching away mid-hold left the microphone open.
        resigned = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, window === self.window else { return }
                self.perform(self.machine.handle(.interrupted).effects)
            }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resigned { NotificationCenter.default.removeObserver(resigned) }
        monitor = nil
        resigned = nil
        if dictation.isActive { discard() }
    }

    /// Whether the event goes on to the app; false means it was used here.
    private func keeps(_ event: NSEvent) -> Bool {
        // Only this window's keys, and never the press being replayed.
        guard !replaying, let window, event.window === window, host != nil else { return true }
        let hold: HoldToTalk.Event
        switch (event.type, event.keyCode) {
        case (.keyDown, Keys.space):
            hold = .spaceDown(isRepeat: event.isARepeat, eligible: eligible(event))
        case (.keyUp, Keys.space):
            hold = .spaceUp
        case (.keyDown, Keys.escape):
            hold = .escape
        case (.keyDown, _):
            hold = .otherKey
        default:
            return true
        }
        if case .spaceDown(isRepeat: false, eligible: true) = hold { heldDown = event }
        let outcome = machine.handle(hold)
        perform(outcome.effects)
        return !outcome.consume
    }

    /// Whether a hold may start: only where a space would be wasted.
    ///
    /// The Ask field when it is empty, or the window when no text is being
    /// edited at all. Anywhere else - half a question typed, a rename field, a
    /// search box - space is a character and passes straight through.
    private func eligible(_ event: NSEvent) -> Bool {
        guard VoiceSettings.holdSpace, let host, host.enabled(), !dictation.isActive,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        if host.fieldFocused() { return host.text.wrappedValue.isEmpty }
        return !(window?.firstResponder is NSText)
    }

    private func perform(_ effects: [HoldToTalk.Effect]) {
        for effect in effects {
            switch effect {
            case .replaySpace:
                // Sent straight to the app rather than posted to the queue, so
                // it is delivered now - ahead of any key that overlapped it -
                // and does not come back through this monitor.
                if let heldDown {
                    replaying = true
                    NSApp.sendEvent(heldDown)
                    replaying = false
                }
                heldDown = nil
            case .startTimer:
                timer += 1
                let mine = timer
                Task { [weak self] in
                    try? await Task.sleep(for: HoldToTalk.threshold)
                    // A timer from an earlier tap must not decide a later press.
                    guard let self, mine == self.timer else { return }
                    self.perform(self.machine.handle(.held).effects)
                }
            case .startRecording:
                // Only the microphone. The field is not focused and nothing is
                // silenced until the hold is certain, so a tap that turns out
                // to be a tap leaves everything as it was.
                begin(byHold: true, confirmed: false)
            case .confirmRecording:
                heldDown = nil
                confirm()
            case .stopRecording:
                finish()
            case .discardRecording:
                discard()
            }
        }
    }

    // ---------------------------------------------------------- dictating

    /// The mic button: start, or stop and keep what was said.
    func toggle() {
        dictation.isActive ? finish() : begin(byHold: false, confirmed: true)
    }

    private func begin(byHold: Bool, confirmed: Bool) {
        guard let host, !dictation.isActive else { return }
        self.byHold = byHold
        typed = host.text.wrappedValue
        dictation.clearFailure()
        dictation.start(vocabulary: host.vocabulary())
        if confirmed { confirm() }
    }

    private func confirm() {
        // Talking over the last answer is how somebody says they have heard
        // enough of it.
        ReadAloud.shared.stop()
        host?.focusField()
    }

    private func finish() {
        guard let host else { return }
        Task {
            let spoken = await dictation.stop()
            host.text.wrappedValue = LiveTranscript.compose(typed: typed, spoken: spoken)
            if !spoken.isEmpty { host.dictated() }
            host.focusField()
        }
    }

    private func discard() {
        dictation.cancel()
        host?.text.wrappedValue = typed
    }

    /// The field was cleared. A dictation still running would write straight
    /// back into it, so it is stopped, and what was typed before it is gone too.
    func cleared() {
        guard dictation.isActive else { return }
        typed = ""
        discard()
    }

    /// Live text for the field while dictation is running.
    func show(_ transcript: LiveTranscript) {
        guard dictation.isActive, let host else { return }
        host.text.wrappedValue = LiveTranscript.compose(typed: typed, spoken: transcript.text)
    }

    /// What the Ask bar's status line says, if anything.
    var status: String? {
        switch dictation.state {
        case .idle: nil
        case .preparing(let why): why
        case .listening: byHold ? "Listening… let go of space to stop, Esc to discard."
                                : "Listening… click the microphone to stop."
        case .finishing: "Finishing…"
        case .failed(let why): why
        }
    }

    private enum Keys {
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
    }
}

/// The mic button in the Ask bar, and the owner of the keyboard monitor.
@available(macOS 26, *)
struct DictateButton: View {
    let host: Talker.Host
    @Binding var status: String?
    /// Bumped by the Ask bar's clear button.
    var clears: Int = 0
    @State private var talker = Talker()

    var body: some View {
        Button { talker.toggle() } label: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(listening ? Palette.danger : Palette.inkSecondary)
                .symbolEffect(.pulse, isActive: listening)
        }
        .buttonStyle(.plain)
        .disabled(!host.enabled() && !talker.dictation.isActive)
        .help(talker.dictation.isActive
              ? "Stop listening"
              : (VoiceSettings.holdSpace ? "Dictate a question (or hold space in the empty field)"
                                         : "Dictate a question"))
        .background(WindowReader { talker.window = $0 })
        .onAppear {
            talker.host = host
            talker.install()
            // Loaded now, so the first hold only has to open the microphone.
            talker.dictation.warm(vocabulary: host.vocabulary())
        }
        .onDisappear { talker.uninstall() }
        .onChange(of: clears) { talker.cleared() }
        .onChange(of: talker.dictation.transcript) { _, transcript in talker.show(transcript) }
        .onChange(of: talker.status, initial: true) { _, now in status = now }
    }

    private var listening: Bool { talker.dictation.state == .listening }

    private var symbol: String {
        switch talker.dictation.state {
        case .listening, .finishing: "mic.fill"
        case .failed: "mic.slash"
        default: "mic"
        }
    }
}

/// The window a SwiftUI view is in, which the key monitor needs so one window's
/// space bar does not start dictation in another.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        probe.found = found
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
        }
    }
}
