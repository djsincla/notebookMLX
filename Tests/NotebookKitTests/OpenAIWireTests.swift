import Foundation
import Network
import Testing
@testable import NotebookKit

/// What this client actually puts on the wire, checked against a server that is
/// not dAI.
///
/// Every other test here asserts what the client does with a reply. None
/// asserted what it *sends*, which is the half that decides whether pointing
/// this at OpenAI, vLLM, LM Studio or anything else compatible works at all.
/// "It is an ordinary OpenAI client" was true by inspection and by nothing else.
///
/// A local listener rather than a real provider: no key, no spend, nothing
/// leaves the machine, and it runs in CI. It speaks the minimum of the protocol
/// and records the request so the shape can be asserted rather than assumed.
struct OpenAIWireTests {

    @Test("sends a request an OpenAI-compatible server accepts, and reads the reply")
    func roundTrip() async throws {
        let server = try StubServer()
        defer { server.stop() }
        let port = try await server.start()

        let gateway = Gateway(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:\(port)")!),
            credential: { "sk-test-key" })

        let answer = try await gateway.answer(
            question: "what is the retention period?",
            passages: [(citation: "Retention Policy", text: "Records are kept seven years.")],
            history: [(question: "hello", answer: "hi")],
            model: "gpt-4o-mini",
            maxTokens: 64)

        // The reply, parsed the way any OpenAI response would be.
        #expect(answer.text == "Seven years (Retention Policy).")
        #expect(answer.model == "gpt-4o-mini")
        #expect(answer.finishReason == "stop")
        // No `dai` object from a third party, and that must be absent rather
        // than a failure: it is the fleet's own annotation.
        #expect(answer.node == nil)
        #expect(answer.cappedByPolicy == false)

        // And the request, which is the part nothing checked before.
        let request = try #require(server.received)
        #expect(request.path == "/v1/chat/completions")
        #expect(request.method == "POST")
        #expect(request.headers["authorization"] == "Bearer sk-test-key")

        let body = try #require(request.json)
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["max_tokens"] as? Int == 64)

        let messages = try #require(body["messages"] as? [[String: String]])
        // system, then the prior turn as user/assistant, then this question.
        #expect(messages.count == 4)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["role"] == "user")
        #expect(messages[2]["role"] == "assistant")
        #expect(messages[3]["role"] == "user")
        // The passages ride in the final user turn, not the system prompt -
        // the prompt cache keys on longest common prefix, so anything that
        // changes every turn has to come last.
        #expect(messages[3]["content"]?.contains("Records are kept seven years.") == true)
        #expect(messages[0]["content"]?.contains("Records are kept seven years.") == false)
    }
}

/// The smallest thing that answers like OpenAI.
///
/// NWListener rather than a package: this needs one endpoint and one canned
/// reply, and a dependency for that would be more code to own than the fifty
/// lines below.
private final class StubServer: @unchecked Sendable {
    struct Request {
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var bodyData = Data()
        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        }
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var _received: Request?
    private var _resumed = false
    var received: Request? { lock.lock(); defer { lock.unlock() }; return _received }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.read(connection, into: Request(), accumulated: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The flag lives behind the lock rather than being captured: a
            // state handler can fire more than once and resuming a
            // continuation twice is a crash, not a warning.
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.claimStart() else { return }
                switch state {
                case .ready:
                    continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                case let .failed(error):
                    continuation.resume(throwing: error)
                default:
                    self.releaseStart()
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }

    /// True exactly once, for whichever state update resolves the start.
    private func claimStart() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _resumed { return false }
        _resumed = true
        return true
    }

    /// Hands the claim back for states that are neither ready nor failed.
    private func releaseStart() {
        lock.lock(); defer { lock.unlock() }
        _resumed = false
    }

    /// Reads until the declared Content-Length has arrived, then answers.
    ///
    /// A single recv is not enough: the body follows the headers in a separate
    /// segment often enough that assuming otherwise makes the test flaky rather
    /// than wrong, which is worse.
    private func read(_ connection: NWConnection, into request: Request, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] chunk, _, isComplete, _ in
            guard let self else { return }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else {
                    self.read(connection, into: request, accumulated: buffer)
                }
                return
            }

            var parsed = Request()
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let start = lines.first?.split(separator: " ") ?? []
            if start.count >= 2 {
                parsed.method = String(start[0])
                parsed.path = String(start[1])
            }
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                parsed.headers[line[..<colon].lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let expected = Int(parsed.headers["content-length"] ?? "0") ?? 0
            let body = buffer[headerEnd.upperBound...]
            guard body.count >= expected else {
                self.read(connection, into: parsed, accumulated: buffer)
                return
            }
            parsed.bodyData = Data(body.prefix(expected))

            self.lock.lock(); self._received = parsed; self.lock.unlock()
            self.respond(on: connection)
        }
    }

    private func respond(on connection: NWConnection) {
        let payload: [String: Any] = [
            "id": "chatcmpl-stub",
            "object": "chat.completion",
            "model": "gpt-4o-mini",
            "choices": [[
                "index": 0,
                "finish_reason": "stop",
                "message": ["role": "assistant",
                            "content": "Seven years (Retention Policy)."],
            ]],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var response = Data("HTTP/1.1 200 OK\r\n".utf8)
        response.append(Data("Content-Type: application/json\r\n".utf8))
        response.append(Data("Content-Length: \(json.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
