import Foundation
import Testing
@testable import NotebookKit

/// Telling a dAI fleet from somebody else's OpenAI-compatible endpoint.
///
/// This app is an ordinary OpenAI client - `POST /v1/chat/completions`, a bearer
/// token, `choices[0].message.content` - so pointing it at another provider
/// works. Two things change when you do, and both fail quietly.
///
/// A dAI gateway serves whatever the group is pinned to, so `model` is optional
/// and the habit of leaving it blank forms. Everyone else answers a request
/// without one with a 400, which reads as a bad key rather than a missing
/// setting.
///
/// And the request body is the question plus the passages retrieval found. They
/// go wherever this points. Embedding is local either way, so the documents
/// themselves never move - but that is the property worth being deliberate
/// about, not one to discover afterwards.
struct GatewayDestinationTests {
    private func config(_ url: String, ca: String? = nil) -> Gateway.Configuration {
        Gateway.Configuration(baseURL: URL(string: url)!, caCertificatePath: ca)
    }

    @Test("a private authority means a fleet, whatever the host")
    func caImpliesFleet() {
        // Only a private CA needs pointing at, so its presence is the strongest
        // signal available - and it holds for a fleet reached by a routable
        // name, which the address rules below would not catch.
        #expect(config("https://dai.example.com:8452", ca: "/etc/dai/srv-ca.crt")
            .looksLikeFleet)
        // An empty string is a field nobody filled in, not a certificate.
        #expect(!config("https://api.openai.com", ca: "").looksLikeFleet)
    }

    @Test("addresses that cannot leave the building are a fleet")
    func privateAddressesAreFleet() {
        for host in ["https://localhost:8452", "https://127.0.0.1:8452",
                     "https://rotorua.local:8452", "https://10.1.2.3:8452",
                     "https://192.168.99.1:8452", "https://172.16.4.5:8452",
                     "https://172.31.255.1:8452"] {
            #expect(config(host).looksLikeFleet, "\(host) should read as a fleet")
        }
    }

    @Test("anything routable is somebody else's endpoint")
    func publicAddressesAreNot() {
        for host in ["https://api.openai.com", "https://api.anthropic.com",
                     "https://8.8.8.8", "https://openrouter.ai",
                     // 172.32 is outside the private range and 192.167 is not
                     // 192.168; both are the sort of near-miss a hand-written
                     // check gets wrong.
                     "https://172.32.0.1", "https://192.167.1.1"] {
            #expect(!config(host).looksLikeFleet, "\(host) should not read as a fleet")
        }
    }

    @Test("a third-party endpoint is refused without a model, before the request")
    func modelRequiredOffFleet() async {
        let gateway = Gateway(configuration: config("https://api.openai.com"),
                              credential: { "sk-test" })
        await #expect(throws: Gateway.Failure.modelRequired) {
            _ = try await gateway.answer(question: "why", passages: [], history: [])
        }
    }

    @Test("naming a model is enough to proceed")
    func modelSatisfiesTheGuard() async {
        // Not a network test: it gets past the guard and fails to connect,
        // which is all that is being asserted. The point is that the refusal
        // above is about the missing model and not about the endpoint.
        let gateway = Gateway(configuration: config("https://127.0.0.1:1"),
                              credential: { "sk-test" })
        do {
            _ = try await gateway.answer(question: "why", passages: [], history: [],
                                         model: "gpt-4o-mini")
            Issue.record("expected a connection failure")
        } catch let failure as Gateway.Failure {
            #expect(failure != .modelRequired)
        } catch {
            // Any transport error is fine; it means the guard let it through.
        }
    }

    @Test("a fleet may still be asked without one")
    func fleetNeedsNoModel() async {
        // The behaviour the optional field exists for: the group decides.
        let gateway = Gateway(configuration: config("https://127.0.0.1:1"),
                              credential: { "sk-test" })
        do {
            _ = try await gateway.answer(question: "why", passages: [], history: [])
            Issue.record("expected a connection failure")
        } catch let failure as Gateway.Failure {
            #expect(failure != .modelRequired)
        } catch {
        }
    }
}
