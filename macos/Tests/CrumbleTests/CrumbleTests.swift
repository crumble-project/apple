import apfelkern
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Crumble

/// Serves canned responses and records requests, so client tests never touch the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let (status, body) = Self.handler?(recorded) ?? (404, "")
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            Issue.record("Invalid stub response")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func client(token: String = "", _ handler: @escaping (URLRequest) -> (Int, String)) -> APIClient {
        self.handler = handler
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(
            baseURL: "http://crumble.test/", token: token, session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized)
struct APIClientTests {
    @Test func agentsSendBearerAndDecode() async throws {
        let client = StubProtocol.client(token: "test-token") { _ in
            (200, agentFixture(#"[{"id":"a1","name":"Atlas","enabled":true,"lastMessage":"See you tomorrow."}]"#))
        }
        let agents = try await client.agents()
        #expect(agents.map(\.name) == ["Atlas"])
        #expect(agents.first?.lastMessage == "See you tomorrow.")
        #expect(StubProtocol.requests.first?.url?.path == "/v1/agents")
        #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func updateAgentCanClearCapabilities() async throws {
        let client = StubProtocol.client { _ in (200, agentFixture(#"{"id":"a1"}"#)) }
        _ = try await client.updateAgent(
            "a1", patch: ["tools": .array([]), "skills": try JSONValue(encoding: [Skill]())])
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(StubProtocol.requests.first?.httpBody))
        #expect(body["tools"] == .array([]) && body["skills"] == .array([]))
    }

    @Test func sharedCatalogIncludesDefaultsAndOptionalSkills() async throws {
        let client = StubProtocol.client { request in
            #expect(request.url?.path == "/v1/skills")
            return (
                200,
                #"""
                [{"id":"common:tasks/SKILL.md","name":"tasks","instructions":"Complete tasks",
                  "source":"bundled","path":"tasks/SKILL.md"},
                 {"id":"s1","name":"Writing","instructions":"Write plainly","source":"shared",
                  "createdAt":"2026-10-19T12:00:00Z","updatedAt":"2026-10-19T12:00:00Z"},
                 {"id":"legacy","name":"Legacy","instructions":"Existing skill","source":"shared",
                  "createdAt":"2026-10-19T12:00:00Z","updatedAt":"2026-10-19T12:00:00Z"}]
                """#
            )
        }
        let skills = try await client.sharedSkills()
        #expect(skills.map(\.isDefault) == [true, false, false])
        #expect(skills.first?.path == "tasks/SKILL.md")
    }

    @Test func chatContracts() async throws {
        let client = StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/agents/a1/chat/history":
                (
                    200,
                    #"""
                    {
                      "messages": [
                        {
                          "id": "a1:8:0",
                          "entryId": "a1:8",
                          "role": "user",
                          "content": "older"
                        }
                      ],
                      "hasMore": false,
                      "oldestEntryId": "a1:8"
                    }
                    """#
                )
            case "/v1/agents/a1/messages": (202, executionFixture())
            default: (404, "")
            }
        }
        let history = try await client.chatHistory("a1", before: "a1:42", limit: 100)
        #expect(history.messages?.first?.entryId == "a1:8")
        #expect(StubProtocol.requests.last?.url?.query == "limit=100&before=a1%3A42")
        try await client.sendChatMessage("a1", content: "hello", requestID: "req", replyTo: "a1:41")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(StubProtocol.requests.last?.httpBody))
        #expect(body["replyTo"]?.stringValue == "a1:41")
    }

    @Test func messagesCarryAttachments() async throws {
        let client = StubProtocol.client { _ in (202, executionFixture()) }
        try await client.sendChatMessage(
            "a1", content: "", requestID: "req", replyTo: "",
            attachments: [OutgoingAttachment(name: "dot.png", mimeType: "image/png", data: "AAAA")])
        let body =
            try JSONSerialization.jsonObject(with: StubProtocol.requests.last?.httpBody ?? Data()) as? [String: Any]
        #expect(body?["replyTo"] == nil)
        #expect((body?["attachments"] as? [[String: String]])?.first?["mimeType"] == "image/png")
        let data = Data(
            #"""
            {"id":"a1:5:0","role":"user","content":"",
             "attachments":[{"name":"dot.png","mimeType":"image/png","size":70,"kind":"image"}]}
            """#.utf8)
        let message = try JSONDecoder().decode(Message.self, from: data)
        #expect(message.attachments?.first?.isImage == true)
        #expect(ChatRow.shownInChat(message))
    }

    @MainActor @Test func failedSendsKeepTheirAttachments() async throws {
        let client = StubProtocol.client { _ in (500, #"{"error":"busy"}"#) }
        let model = AppModel(client: client)
        model.snapshot = ChatSnapshot(status: "idle", agentId: "a1")
        model.attachments = [PendingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8))]
        model.sendMessage()
        #expect(model.attachments.isEmpty)
        while model.sending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.attachments.map(\.name) == ["notes.txt"])
        #expect(model.errorText.contains("busy"))
    }

    @Test func mcpSignInRoundTrip() async throws {
        let client = StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/mcp-servers/s1/oauth":
                (200, #"{"authorizationUrl":"https://auth.example.com/authorize?state=x"}"#)
            case "/v1/mcp-servers/s1/oauth/callback":
                (200, #"{"id":"s1","name":"Linear","url":"https://mcp.linear.app/mcp","enabled":true,"agentId":null,"auth":"oauth","authenticated":true}"#)
            default: (404, "")
            }
        }
        let start = try await client.startMCPSignIn("s1", redirectURI: AppModel.oauthRedirectURI)
        #expect(start.authorizationUrl?.hasPrefix("https://auth.example.com/") == true)
        let sent = try #require(String(data: StubProtocol.requests.last?.httpBody ?? Data(), encoding: .utf8))
        let scheme = AppIdentity.bundleID
        #expect(sent.contains(scheme + ":\\/oauth\\/callback") || sent.contains(scheme + ":/oauth/callback"))
        let server = try await client.finishMCPSignIn("s1", code: "c", state: "x", iss: "https://auth.example.com")
        #expect(server.auth == "oauth")
        let finished = try JSONDecoder().decode(JSONValue.self, from: #require(StubProtocol.requests.last?.httpBody))
        #expect(finished["iss"]?.stringValue == "https://auth.example.com")
    }

    @Test func errorsCarryStatusAndBody() async throws {
        let client = StubProtocol.client { _ in (401, "bad token") }
        do {
            _ = try await client.agents()
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error.statusCode == 401 && error.body == "bad token")
            #expect(friendlyError(error) == "Authentication failed. Check the server token in Settings.")
        }
    }

    @Test func scheduleRunUnwrapsTheEnvelope() async throws {
        let client = StubProtocol.client { _ in (202, #"{"admitted":true,"result":{"id":"e1","status":"pending"}}"#) }
        #expect(try await client.runSchedule("s1").id == "e1")
    }

    @MainActor @Test func taskPickersPreserveTheInstantAndSubmitOnlyTheSelectedMode() async throws {
        let response =
            #"""
            {"id":"s1","agentId":"a1","name":"Greeting","prompt":"Say hi","enabled":true,
             "timezone":"Europe/Berlin","runAt":"2026-10-18T10:10:00Z"}
            """#
        let client = StubProtocol.client { request in
            (200, request.httpMethod == "PATCH" ? scheduleFixture(response) : "[]")
        }
        let model = AppModel(client: client)
        model.agents = [Agent(id: "a1", name: "Atlas")]
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(response.utf8))
        for repeats in [false, true] {
            model.schedules = [schedule]
            model.openTaskForm("s1")
            let draft = try #require(model.taskDraft)
            #expect(!draft.repeats)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: draft.timezone))
            #expect(calendar.component(.hour, from: draft.runDate) == 12)
            #expect(calendar.component(.minute, from: draft.runDate) == 10)
            model.taskDraft?.repeats = repeats
            model.saveTask()
            for _ in 0..<100 {
                if !model.loading { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!model.loading)
            #expect(model.errorText.isEmpty)
            let request = try #require(StubProtocol.requests.last { $0.httpMethod == "PATCH" })
            let data = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if repeats {
                #expect(payload["cron"] as? String == "0 9 * * *")
                #expect(payload["runAt"] is NSNull)
            } else {
                #expect(taskRunDate(payload["runAt"] as? String ?? "") == draft.runDate)
                #expect(payload["cron"] is NSNull)
            }
        }
    }

    @Test func chatEventsDeliverSnapshotsThenReportClosing() async throws {
        let payload = chatFixture("a7", status: "running").replacingOccurrences(of: ",", with: ",\n")
        let client = StubProtocol.client { request in
            #expect(request.url?.path == "/v1/agents/a7/events")
            return (
                200,
                "event: heartbeat\ndata: {}\n\n" +
                    "event: snapshot\ndata: " + payload.replacingOccurrences(of: "\n", with: "\ndata: ") + "\n\n"
            )
        }
        let received = Received()
        do {
            try await client.chatEvents("a7") { await received.append($0) }
        } catch is SSEClosedError {}
        #expect(await received.payloads == [payload])
    }
}

actor Received {
    var payloads: [String] = []
    func append(_ payload: String) { payloads.append(payload) }
}
