import AVFoundation
import NotebookKit
import Observation
import os
import Speech

/// Speech in, text out, without the audio leaving this Mac.
///
/// SpeechAnalyzer with SpeechTranscriber, which runs on-device and reports a
/// volatile guess while somebody is still talking, so the field fills as they
/// speak rather than after they stop. The older recogniser was the alternative
/// and it is noticeably worse at exactly what a notebook question is made of:
/// product names, filenames and long sentences.
///
/// **The model is installed once, from Apple.** SpeechTranscriber's language
/// model is a system asset, not part of this app, and the first dictation on a
/// Mac that has never used it downloads it. That is said on screen when it
/// happens. The audio itself is never sent anywhere.
///
/// **The next session is always ready before it is asked for.** Building one -
/// finding the locale, checking the model is installed, loading the analyzer -
/// was done on the key press, and the first words of every question were spoken
/// into a microphone that was not open yet. Now it is built ahead of time, when
/// the Ask bar appears and again as each dictation ends, so a press only has to
/// open the microphone. Nothing is recorded ahead of time: the microphone opens
/// on the press and closes on the release.
@available(macOS 26, *)
@Observable @MainActor
final class Dictation {

    enum State: Equatable {
        case idle
        /// Getting ready, with the reason said: the first run can take a while
        /// and a silent pause reads as the button not working.
        case preparing(String)
        case listening
        case finishing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript = LiveTranscript()

    var isActive: Bool {
        switch state {
        case .preparing, .listening, .finishing: true
        case .idle, .failed: false
        }
    }

    /// An analyzer loaded and waiting for audio, and a microphone ready to
    /// start - built, tapped and prepared, but not running, so nothing is heard
    /// until a press starts it.
    ///
    /// Unchecked because AVAudioEngine is not Sendable. It is made, stored and
    /// taken only on the main actor; the Task that carries it never leaves.
    private struct Ready: @unchecked Sendable {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
        var vocabulary: [String]
        let engine: AVAudioEngine
        let stream: AsyncStream<AnalyzerInput>
        let continuation: AsyncStream<AnalyzerInput>.Continuation
    }

    @ObservationIgnored private var ready: Ready?
    @ObservationIgnored private var readying: Task<Ready, Error>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// Bumped by every start and cancel, so a start that finishes preparing
    /// after it was called off does not open the microphone anyway.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var clock = Timing()

    /// Get the next session ready without opening the microphone.
    ///
    /// Only when that needs nobody's permission: the microphone already
    /// allowed, and dictation already used on this Mac. A permission prompt or
    /// a model download that nobody asked for, triggered by opening a window,
    /// would be a strange thing for a notebook to do; the first real press does
    /// those.
    ///
    /// **The installation request is not a download once dictation has
    /// worked.** The framework asks for one on every launch, even with the
    /// model already on the Mac, and completes it in a fraction of a second.
    /// Treating every request as a download stopped the warm-up every time,
    /// silently, and each press paid 1.7 seconds building an analyzer while its
    /// first words went unheard.
    func warm(vocabulary: [String]) {
        guard ready == nil, readying == nil, !isActive, VoiceSettings.dictationWorked,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let task = Task { try await Self.makeReady(vocabulary: vocabulary, download: {}) }
        readying = task
        Task { [weak self] in
            let made: Ready?
            do {
                made = try await task.value
            } catch {
                made = nil
                Self.log.error("warm-up failed: \(String(describing: error), privacy: .public)")
            }
            // Only if nothing took the task in the meantime. A start that
            // awaited it is already using what it made.
            guard let self, self.readying == task else {
                if let made { Self.discard(made) }
                return
            }
            self.readying = nil
            self.ready = made
        }
    }

    /// Begin listening.
    ///
    /// `vocabulary` is words the recogniser should expect - the open notebook's
    /// source titles - offered as context. It biases recognition toward them;
    /// it does not force them.
    func start(vocabulary: [String]) {
        guard !isActive else { return }
        session += 1
        let mine = session
        clock = Timing()
        transcript = LiveTranscript()
        state = .preparing("Starting the microphone…")
        starting = Task { [weak self] in
            await self?.begin(vocabulary: vocabulary, session: mine)
        }
    }

    /// Stop listening and return everything heard.
    ///
    /// Waits for the recogniser to finalise what it already has, because the
    /// last words of a question are usually still volatile at the moment the
    /// key comes up, and dropping them loses the end of the sentence.
    func stop() async -> String {
        clock.mark("released")
        await starting?.value
        guard state == .listening else {
            if case .preparing = state { cancel() }
            return transcript.text
        }
        state = .finishing
        closeMicrophone()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // What was heard before the failure is still what was said.
        }
        await reading?.value
        clock.mark("final text")
        clock.report()
        let vocabulary = currentVocabulary
        teardown()
        state = .idle
        warm(vocabulary: vocabulary)
        return transcript.text
    }

    /// Stop and throw away what was heard.
    func cancel() {
        session += 1
        starting?.cancel()
        closeMicrophone()
        reading?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        let vocabulary = currentVocabulary
        teardown()
        transcript = LiveTranscript()
        state = .idle
        warm(vocabulary: vocabulary)
    }

    func clearFailure() {
        if case .failed = state { state = .idle }
    }

    @ObservationIgnored private var currentVocabulary: [String] = []

    // ------------------------------------------------------------ starting

    private func begin(vocabulary: [String], session mine: Int) async {
        currentVocabulary = vocabulary
        do {
            try await requireMicrophone()
            guard session == mine else { return }
            let ready = try await take(vocabulary: vocabulary)
            guard session == mine else { Self.discard(ready); return }

            self.engine = ready.engine
            self.analyzer = ready.analyzer
            self.input = ready.continuation
            try ready.engine.start()
            clock.mark("microphone open")
            let transcriber = ready.transcriber
            reading = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        if self.transcript.text.isEmpty { self.clock.mark("first words") }
                        self.transcript.apply(String(result.text.characters),
                                              isFinal: result.isFinal)
                    }
                } catch {
                    // The sequence ends with an error when cancelled, which is
                    // the normal way out of a discarded dictation.
                }
            }
            try await ready.analyzer.start(inputSequence: ready.stream)
            state = .listening
            VoiceSettings.dictationWorked = true
            clock.mark("listening")
        } catch {
            guard session == mine else { return }
            closeMicrophone()
            teardown()
            state = .failed((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    /// The analyzer made ahead of time if there is one, otherwise one made now.
    private func take(vocabulary: [String]) async throws -> Ready {
        var made: Ready?
        if let ready {
            self.ready = nil
            made = ready
            clock.mark("ready (made earlier)")
        } else if let readying {
            self.readying = nil
            do {
                made = try await readying.value
                clock.mark("ready (was being made)")
            } catch {
                Self.log.error("warm-up failed: \(String(describing: error), privacy: .public)")
            }
        }
        if var made {
            // The notebook's sources may have changed since it was made.
            if made.vocabulary != vocabulary {
                try? await made.analyzer.setContext(Self.context(vocabulary))
                made.vocabulary = vocabulary
            }
            return made
        }
        let fresh = try await Self.makeReady(vocabulary: vocabulary) { [weak self] in
            self?.state = .preparing("Downloading the speech model from Apple (once)…")
        }
        clock.mark("ready (made now)")
        return fresh
    }

    /// Build an analyzer and load its model.
    ///
    /// `download` is called before the model is fetched; nil means a missing
    /// model is a reason to stop rather than to fetch it.
    private static func makeReady(vocabulary: [String],
                                  download: (@MainActor () -> Void)?) async throws -> Ready {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        else {
            throw Failure("Dictation is not available for \(Locale.current.identifier) on this Mac.")
        }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            // Fast results trade a little accuracy in the first guess for
            // words on screen sooner. The final reading that replaces the guess
            // is unaffected, and that is what gets asked.
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) {
            guard let download else { throw Failure("The speech model is not installed yet.") }
            download()
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            // Kept loaded after use, so the second question in a conversation
            // does not pay the model load the first one did.
            options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw Failure("The speech model accepts no audio format this Mac can record.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        if !vocabulary.isEmpty {
            // Best effort: a context the model declines is a small loss in
            // accuracy, not a reason to refuse to listen.
            try? await analyzer.setContext(context(vocabulary))
        }
        // The audio side too, short of starting it. Starting an engine that is
        // already built and tapped is the only part left for the key press.
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let engine = AVAudioEngine()
        try Microphone.tap(engine, into: continuation, as: format)
        engine.prepare()
        return Ready(transcriber: transcriber, analyzer: analyzer, format: format,
                     vocabulary: vocabulary, engine: engine, stream: stream,
                     continuation: continuation)
    }

    /// Let go of a session that was made and never used.
    private static func discard(_ ready: Ready) {
        ready.engine.inputNode.removeTap(onBus: 0)
        ready.continuation.finish()
        let analyzer = ready.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private static let log = Logger(subsystem: "com.dai.notebookmlx", category: "dictation")

    private static func context(_ vocabulary: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        return context
    }

    /// Ask for the microphone the first time, and explain a refusal after.
    private func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            fallthrough
        default:
            throw Failure("notebookMLX is not allowed to use the microphone. "
                + "Turn it on in System Settings › Privacy & Security › Microphone.")
        }
    }

    // ------------------------------------------------------------- stopping

    private func closeMicrophone() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        input?.finish()
    }

    private func teardown() {
        engine = nil
        input = nil
        analyzer = nil
        reading = nil
        starting = nil
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Where the time goes in one dictation, written to the unified log.
    ///
    /// "Slow" has at least four places to live - opening the microphone,
    /// loading the model, the first words, and finalising after the release -
    /// and each wants a different fix. Read it with:
    ///
    ///     log show --last 5m --predicate 'subsystem == "com.dai.notebookmlx"'
    struct Timing {
        private let started = ContinuousClock.now
        private var marks: [(String, Duration)] = []
        private static let log = Logger(subsystem: "com.dai.notebookmlx", category: "dictation")

        mutating func mark(_ what: String) {
            marks.append((what, ContinuousClock.now - started))
        }

        func report() {
            let line = marks.map { "\($0.0) +\($0.1.milliseconds)ms" }.joined(separator: ", ")
            Self.log.notice("dictation: \(line, privacy: .public)")
        }
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}

/// The audio tap, kept off the main actor.
///
/// The tap block runs on a real-time audio thread. Formed inside a main-actor
/// type it would inherit that isolation, and Swift 6 checks isolation at run
/// time - the first buffer would stop the app. Built here, in a nonisolated
/// context, it is an ordinary closure.
@available(macOS 26, *)
enum Microphone {
    nonisolated static func tap(_ engine: AVAudioEngine,
                                into continuation: AsyncStream<AnalyzerInput>.Continuation,
                                as format: AVAudioFormat) throws {
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else {
            throw Dictation.Failure("No microphone is connected.")
        }
        let converter = natural == format ? nil : AVAudioConverter(from: natural, to: format)
        if natural != format && converter == nil {
            throw Dictation.Failure("The microphone's audio cannot be converted for the speech model.")
        }
        let feed = Feed(converter: converter, format: format, continuation: continuation)
        // Small buffers, so audio reaches the recogniser every ~20 ms rather
        // than every ~85 ms. The first words are what a slow start is felt as.
        node.installTap(onBus: 0, bufferSize: 1024, format: natural) { buffer, _ in
            feed.push(buffer)
        }
    }

    /// Converts each buffer to the model's format and hands it on.
    ///
    /// Unchecked because AVAudioConverter is not Sendable; it is only ever used
    /// from the one audio thread that calls the tap.
    final class Feed: @unchecked Sendable {
        let converter: AVAudioConverter?
        let format: AVAudioFormat
        let continuation: AsyncStream<AnalyzerInput>.Continuation

        init(converter: AVAudioConverter?, format: AVAudioFormat,
             continuation: AsyncStream<AnalyzerInput>.Continuation) {
            self.converter = converter
            self.format = format
            self.continuation = continuation
        }

        func push(_ buffer: AVAudioPCMBuffer) {
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            let once = Once(buffer)
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                guard let buffer = once.take() else {
                    status.pointee = .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
    }

    /// One buffer, handed to the converter once.
    ///
    /// The converter's input block is declared @Sendable but is called
    /// synchronously, inside `convert`, on the thread that called it. This is
    /// the state that call needs, in a form the compiler can accept.
    final class Once: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}
