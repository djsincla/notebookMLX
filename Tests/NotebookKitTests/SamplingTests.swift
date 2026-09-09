import Foundation
import Testing
@testable import NotebookKit

/// What gets sent, and what deliberately does not.
///
/// The whole design rests on one rule: an unset preference sends no field at
/// all. A notebook that shipped `temperature: 0` in every request would be
/// quietly overriding whatever the endpoint chose for itself - greedy on a dAI
/// fleet, but 0.7 on LM Studio and on OpenAI - so a reader who never opened
/// Settings would get different answers from the same server than everything
/// else gets, with nothing on screen saying why.
struct SamplingRequestTests {
    @Test("unset sends nothing at all")
    func endpointDefaultIsEmpty() {
        #expect(Sampling.endpointDefault.requestFields(isDaiFleet: true).isEmpty)
        #expect(Sampling.endpointDefault.requestFields(isDaiFleet: false).isEmpty)
        #expect(Sampling.endpointDefault.isEndpointDefault)
    }

    @Test("sends what was set, under the OpenAI names")
    func setFields() {
        let s = Sampling(temperature: 0.7, topP: 0.9, stop: ["</task>"])
        let fields = s.requestFields(isDaiFleet: false)
        #expect(fields["temperature"] as? Double == 0.7)
        #expect(fields["top_p"] as? Double == 0.9)
        #expect(fields["stop"] as? [String] == ["</task>"])
    }

    @Test("temperature 0 is a value, not an absence")
    func zeroIsSent() {
        // The trap this design exists to avoid. Greedy is a real choice and has
        // to reach the endpoint, or "Custom, temperature 0" against OpenAI
        // would silently be OpenAI's own 0.7 - the setting on screen and the
        // answer produced disagreeing, with no way to tell from either.
        let fields = Sampling(temperature: 0).requestFields(isDaiFleet: false)
        #expect(fields["temperature"] as? Double == 0)
    }

    @Test("the repetition penalty goes only to a fleet")
    func penaltyIsFleetOnly() {
        // OpenAI answers 400 for a body field it does not recognise, and the
        // refusal names nothing - which on a first question reads as a bad key,
        // because that is the other thing that produces one.
        let s = Sampling(temperature: 0.7, repetitionPenalty: 1.1)
        #expect(s.requestFields(isDaiFleet: true)["repetition_penalty"] as? Double == 1.1)
        #expect(s.requestFields(isDaiFleet: false)["repetition_penalty"] == nil)
        // And the temperature still goes, because dropping the one unsupported
        // field must not drop the request's other settings with it.
        #expect(s.requestFields(isDaiFleet: false)["temperature"] as? Double == 0.7)
    }

    @Test("says on screen what it will not send")
    func namesWhatIsIgnored() {
        // A setting that is stored, displayed and silently ignored is worse
        // than one never offered: the reader has already decided the question
        // is answered.
        let s = Sampling(temperature: 0.7, repetitionPenalty: 1.1)
        #expect(s.ignored(isDaiFleet: false) == ["Repetition penalty"])
        #expect(s.ignored(isDaiFleet: true).isEmpty)
        #expect(Sampling(temperature: 0.7).ignored(isDaiFleet: false).isEmpty)
    }

    @Test("an empty stop list is absent rather than empty")
    func emptyStop() {
        // `stop: []` is a field OpenAI accepts and some servers reject, and it
        // asks for nothing either way.
        #expect(Sampling(temperature: 0).requestFields(isDaiFleet: true)["stop"] == nil)
    }

    @Test("survives being saved and read back")
    func roundTripsThroughJSON() throws {
        let s = Sampling(temperature: 0, topP: 0.9, repetitionPenalty: 1.1,
                         stop: ["\n\nHuman:"])
        let back = try JSONDecoder().decode(
            Sampling.self, from: JSONEncoder().encode(s))
        // Temperature 0 in particular: stored as one blob precisely so that
        // "never chosen" and "chosen as zero" stay different, which four
        // separate defaults keys could not express.
        #expect(back == s)
        #expect(back.temperature == 0)
    }
}

/// Stop sequences as one line of text.
struct StopListTests {
    @Test("reads a comma separated line")
    func parses() {
        #expect(StopList.parse("</task>, END") == ["</task>", "END"])
        #expect(StopList.parse("") == [])
        #expect(StopList.parse("  ,  ") == [])
    }

    @Test("writes invisible characters as escapes, both ways")
    func escapes() {
        // The sequences worth setting are mostly invisible, and a field that
        // cannot express them can only express the ones nobody needs.
        #expect(StopList.parse(#"\n\nHuman:"#) == ["\n\nHuman:"])
        #expect(StopList.text(["\n\nHuman:"]) == #"\n\nHuman:"#)
        #expect(StopList.parse(#"a\tb"#) == ["a\tb"])
    }

    @Test("a round trip is what was typed")
    func roundTrips() {
        for line in [#"</task>"#, #"\n\nHuman:, END"#, #"a\\b"#] {
            #expect(StopList.text(StopList.parse(line)) == line, "\(line)")
        }
    }

    @Test("an unknown escape is left alone rather than eaten")
    func unknownEscape() {
        // Not a general unescaper on purpose. Swallowing a backslash nobody
        // meant as an escape would send a different string than the one on
        // screen, which is the whole thing escapes exist here to prevent.
        #expect(StopList.parse(#"\q"#) == [#"\q"#])
    }
}
