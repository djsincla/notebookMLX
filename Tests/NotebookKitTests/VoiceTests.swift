import Testing
@testable import NotebookKit

/// An answer read aloud should be the answer, not its typesetting.
@Suite("Speakable text")
struct SpeakableTextTests {

    @Test("drops a citation the answer names, and the brackets around it")
    func citationDropped() {
        let spoken = SpeakableText.from(
            answer: "Add the host first (vcf-9-1.pdf p2518 (2/6)), then commission it.",
            citations: ["vcf-9-1.pdf p2518 (2/6)"])
        #expect(spoken == "Add the host first, then commission it.")
    }

    @Test("drops two citations listed together without leaving their comma")
    func twoCitations() {
        let spoken = SpeakableText.from(
            answer: "Both apply (a-guide.pdf p12, b-manual.pdf p40).",
            citations: ["a-guide.pdf p12", "b-manual.pdf p40"])
        #expect(spoken == "Both apply.")
    }

    /// The same rule as linking: only names the turn actually cited. Something
    /// shaped like a filename that was not retrieved is part of the sentence.
    @Test("keeps text that only looks like a citation")
    func conservative() {
        let spoken = SpeakableText.from(
            answer: "Edit settings.json p1 to change it.",
            citations: ["other-document.pdf p9"])
        #expect(spoken == "Edit settings.json p1 to change it.")
    }

    @Test("reads markdown as its words")
    func markdown() {
        let answer = """
        ## Steps
        - **Stop** the `dai-agent` service
        - Read [the manual](https://example.com/manual) first
        """
        let spoken = SpeakableText.from(answer: answer, citations: [])
        #expect(spoken == "Steps.\nStop the dai-agent service.\nRead the manual first.")
    }

    @Test("does not read an address aloud")
    func bareURL() {
        let spoken = SpeakableText.from(
            answer: "The console is at https://control.example.com:8452/ui/ for admins.",
            citations: [])
        #expect(spoken == "The console is at for admins.")
    }

    @Test("keeps the code inside a fence and drops the fence")
    func fence() {
        let spoken = SpeakableText.from(
            answer: "Run:\n```sh\nsudo launchctl kickstart\n```",
            citations: [])
        #expect(spoken == "Run:\nsudo launchctl kickstart.")
    }

    @Test("reads a table row by row")
    func table() {
        let spoken = SpeakableText.from(
            answer: "| Port | Use |\n|---|---|\n| 8452 | admin |",
            citations: [])
        #expect(spoken == "Port, Use.\n8452, admin.")
    }

    @Test("leaves plain prose alone")
    func prose() {
        let answer = "The group serves one model. It listens on port 8463."
        #expect(SpeakableText.from(answer: answer, citations: []) == answer)
    }
}

/// Volatile guesses replace each other; finals accumulate.
@Suite("Live transcript")
struct LiveTranscriptTests {

    @Test("a newer guess replaces the last one rather than adding to it")
    func volatileReplaces() {
        var t = LiveTranscript()
        t.apply("how do", isFinal: false)
        t.apply("how do I add", isFinal: false)
        #expect(t.text == "how do I add")
    }

    @Test("a final replaces its guess and later speech follows it")
    func finalThenMore() {
        var t = LiveTranscript()
        t.apply("how do I add", isFinal: false)
        t.apply("How do I add a host?", isFinal: true)
        t.apply("to the", isFinal: false)
        #expect(t.text == "How do I add a host? to the")
        t.apply(" To the cluster.", isFinal: true)
        #expect(t.text == "How do I add a host? To the cluster.")
        #expect(t.volatile.isEmpty)
    }

    @Test("dictation adds to what was typed rather than replacing it")
    func compose() {
        #expect(LiveTranscript.compose(typed: "In the manual, ", spoken: "how do I add a host?")
                == "In the manual, how do I add a host?")
        #expect(LiveTranscript.compose(typed: "", spoken: "hello") == "hello")
        #expect(LiveTranscript.compose(typed: "typed", spoken: "") == "typed")
    }
}

/// Space is both a character and the talk key; these are the ways it can go.
@Suite("Hold to talk")
struct HoldToTalkTests {

    /// The microphone opens on the press. Waiting for the hold to be certain
    /// lost a fast talker's first words.
    @Test("recording starts on the press, before the hold is certain")
    func recordsOnPress() {
        var h = HoldToTalk()
        #expect(h.handle(.spaceDown(isRepeat: false, eligible: true))
                == .swallow(.startRecording, .startTimer))
    }

    @Test("a tap throws away what it heard and is replayed as a space")
    func tap() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        #expect(h.handle(.spaceUp) == .swallow(.discardRecording, .replaySpace))
        #expect(h.state == .idle)
    }

    @Test("a hold records until space comes up")
    func hold() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        #expect(h.handle(.held) == .swallow(.confirmRecording))
        #expect(h.handle(.spaceDown(isRepeat: true, eligible: true)) == .swallow())
        #expect(h.handle(.spaceUp) == .swallow(.stopRecording))
        #expect(h.state == .idle)
    }

    @Test("autorepeat while deciding types nothing")
    func repeatWhileDeciding() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        #expect(h.handle(.spaceDown(isRepeat: true, eligible: true)) == .swallow())
    }

    @Test("space passes straight through where a hold may not start")
    func ineligible() {
        var h = HoldToTalk()
        #expect(h.handle(.spaceDown(isRepeat: false, eligible: false)) == .pass)
        #expect(h.handle(.spaceUp) == .pass)
        #expect(h.state == .idle)
    }

    @Test("a timer that fires after a tap does nothing")
    func staleTimer() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        _ = h.handle(.spaceUp)
        #expect(h.handle(.held) == .pass)
        #expect(h.state == .idle)
    }

    @Test("overlapping keys from fast typing keep their order")
    func rollover() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        let outcome = h.handle(.otherKey)
        #expect(outcome == HoldToTalk.Outcome(consume: false,
                                              effects: [.discardRecording, .replaySpace]))
        #expect(h.state == .idle)
    }

    @Test("escape throws the recording away and the release types nothing")
    func escape() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        _ = h.handle(.held)
        #expect(h.handle(.escape) == .swallow(.discardRecording))
        #expect(h.handle(.spaceUp) == .swallow())
        #expect(h.state == .idle)
    }

    @Test("losing focus while recording stops rather than leaving the mic open")
    func interrupted() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        _ = h.handle(.held)
        #expect(h.handle(.interrupted) == .swallow(.stopRecording))
        #expect(h.state == .idle)
    }

    @Test("other keys still work while recording")
    func shortcutsWhileRecording() {
        var h = HoldToTalk()
        _ = h.handle(.spaceDown(isRepeat: false, eligible: true))
        _ = h.handle(.held)
        #expect(h.handle(.otherKey) == .pass)
        #expect(h.state == .recording)
    }
}
