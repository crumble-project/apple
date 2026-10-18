import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import Crumble

/// Canned URL responses for tests; no test reaches the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
  nonisolated(unsafe) static var requests: [URLRequest] = []
  nonisolated(unsafe) private static var sessionID = ""

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
    // Cancelled SSE requests can arrive after the next test starts. Keep them out of the
    // next session's handler and request log instead of reusing its canned responses.
    let current = recorded.value(forHTTPHeaderField: "X-Crumble-Test-Session") == Self.sessionID
    if current { Self.requests.append(recorded) }
    let (status, body) = current ? Self.handler?(recorded) ?? (404, "") : (401, "")
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
    else {
      Issue.record("The stub could not create an HTTP response.")
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func client(token: String = "", _ handler: @escaping (URLRequest) -> (Int, String))
    -> APIClient {
    self.handler = handler
    requests = []
    let configuration = URLSessionConfiguration.ephemeral
    sessionID = UUID().uuidString
    configuration.httpAdditionalHeaders = ["X-Crumble-Test-Session": sessionID]
    configuration.protocolClasses = [StubProtocol.self]
    return APIClient(
      baseURL: "http://crumble.test/", token: token,
      session: URLSession(configuration: configuration))
  }
}

@Suite(.serialized)
struct APIClientTests {
  @Test func agentsSendBearerAndDecode() async throws {
    let client = StubProtocol.client(token: "test-token") { _ in
      (200, #"[{"id":"a1","name":"Atlas","enabled":true,"lastMessage":"See you tomorrow."}]"#)
    }
    let agents = try await client.agents()
    #expect(agents.map(\.name) == ["Atlas"])
    #expect(agents.first?.lastMessage == "See you tomorrow.")
    #expect(StubProtocol.requests.first?.url?.path == "/v1/agents")
    #expect(
      StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
    )
  }

  @Test func updateAgentCanClearCapabilities() async throws {
    let client = StubProtocol.client { _ in (200, #"{"id":"a1"}"#) }
    _ = try await client.updateAgent(
      "a1", patch: ["tools": .array([]), "skills": try JSONValue(encoding: [Skill]())])
    let body = try #require(String(data: StubProtocol.requests.first?.httpBody ?? Data(), encoding: .utf8))
    #expect(body.contains(#""tools":[]"#) && body.contains(#""skills":[]"#))
  }

  @Test func sharedCatalogIncludesDefaultsAndOptionalSkills() async throws {
    let client = StubProtocol.client { request in
      #expect(request.url?.path == "/v1/skills")
      return (
        200,
        #"""
        [{"id":"common:tasks/SKILL.md","name":"tasks","instructions":"Complete tasks",
        "source":"bundled","path":"tasks/SKILL.md"},
        {"id":"s1","name":"Writing","instructions":"Write plainly","source":"shared"},
        {"id":"legacy","name":"Legacy","instructions":"Existing skill"}]
        """#
      )
    }
    let skills = try await client.sharedSkills()
    #expect(skills.map(\.isDefault) == [true, false, false])
    #expect(skills.first?.path == "tasks/SKILL.md")
  }

  @MainActor @Test func memoryOverviewLoadsEveryBotWithoutSelectingOne() async throws {
    let client = StubProtocol.client { request in
      switch request.url?.path {
      case "/v1/agents": (200, #"[{"id":"a1","name":"Atlas"},{"id":"a2","name":"Beacon"}]"#)
      case "/v1/memories": (200, #"[{"id":"shared","content":"For every bot"}]"#)
      case "/v1/agents/a1/memories": (200, #"[{"id":"personal-1","content":"Only Atlas"}]"#)
      case "/v1/agents/a2/memories": (200, #"[{"id":"personal-2","content":"Only Beacon"}]"#)
      default: (404, "")
      }
    }
    let model = AppModel(client: client)
    model.openPanel(.memory)
    for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.loading)
    #expect(model.route == .memory)
    #expect(model.selectedAgentID.isEmpty)
    #expect(model.agents.map(\.id) == ["a1", "a2"])
    #expect(model.agentMemories["a1"]?.map(\.id) == ["personal-1"])
    #expect(model.agentMemories["a2"]?.map(\.id) == ["personal-2"])
    #expect(model.sharedMemories.map(\.id) == ["shared"])
    #expect(model.errorText.isEmpty)
    #expect(StubProtocol.requests.allSatisfy { $0.url?.path.contains("/chat") == false })
  }

  @MainActor @Test func failedSendsKeepTheirAttachments() async throws {
    let model = AppModel(client: StubProtocol.client { _ in (500, #"{"error":"busy"}"#) })
    model.snapshot = ChatSnapshot(status: "idle", agentId: "a1")
    model.attachments = [
      PendingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8))
    ]
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
        (
          200,
          #"{"id":"s1","name":"Linear","url":"https://mcp.linear.app/mcp","enabled":true,"auth":"oauth"}"#
        )
      default: (404, "")
      }
    }
    let start = try await client.startMCPSignIn("s1", redirectURI: AppModel.oauthRedirectURI)
    #expect(start.authorizationUrl?.hasPrefix("https://auth.example.com/") == true)
    let sent = try #require(String(data: StubProtocol.requests.last?.httpBody ?? Data(), encoding: .utf8))
    #expect(
      sent.contains("dev.crumble.ios:\\/oauth\\/callback")
        || sent.contains("dev.crumble.ios:/oauth/callback"))
    let server = try await client.finishMCPSignIn(
      "s1", code: "c", state: "x", iss: "https://auth.example.com")
    #expect(server.auth == "oauth")
    let finished = try #require(String(data: StubProtocol.requests.last?.httpBody ?? Data(), encoding: .utf8))
    #expect(
      finished.contains(#""iss":"https:\/\/auth.example.com""#)
        || finished.contains(#""iss":"https://auth.example.com""#))
  }

  @Test func chatContracts() async throws {
    let client = StubProtocol.client { request in
      switch request.url?.path {
      case "/v1/agents/a1/chat/history":
        (
          200,
          #"{"messages":[{"entryId":"a1:8","role":"user","content":"older"}],"hasMore":false,"oldestEntryId":"a1:8"}"#
        )
      case "/v1/agents/a1/messages": (202, "")
      default: (404, "")
      }
    }
    let history = try await client.chatHistory("a1", before: "a1:42", limit: 100)
    #expect(history.messages?.first?.entryId == "a1:8")
    #expect(StubProtocol.requests.last?.url?.query == "before=a1%3A42&limit=100")
    try await client.sendChatMessage("a1", content: "hello", requestID: "req", replyTo: "a1:41")
    let body = try #require(String(data: StubProtocol.requests.last?.httpBody ?? Data(), encoding: .utf8))
    #expect(body.contains(#""replyTo":"a1:41""#))
  }

  @Test func messagesCarryAttachments() async throws {
    let client = StubProtocol.client { _ in (202, "") }
    try await client.sendChatMessage(
      "a1", content: "", requestID: "req", replyTo: "",
      attachments: [OutgoingAttachment(name: "dot.png", mimeType: "image/png", data: "AAAA")])
    let body =
      try JSONSerialization.jsonObject(with: StubProtocol.requests.last?.httpBody ?? Data())
      as? [String: Any]
    #expect(body?["replyTo"] == nil)
    #expect((body?["attachments"] as? [[String: String]])?.first?["mimeType"] == "image/png")
    let message = try JSONDecoder().decode(
      Message.self,
      from: Data(
        #"""
        {"id":"a1:5:0","role":"user","content":"",
        "attachments":[{"name":"dot.png","mimeType":"image/png","size":70,"kind":"image"}]}
        """#
          .utf8))
    #expect(message.attachments?.first?.isImage == true)
    #expect(ChatRow.shownInChat(message))
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
    let client = StubProtocol.client { _ in
      (200, #"{"admitted":true,"result":{"id":"e1","status":"pending"}}"#)
    }
    #expect(try await client.runSchedule("s1").id == "e1")
  }

  @Test func chatEventsDeliverSnapshotsThenReportClosing() async throws {
    let client = StubProtocol.client { request in
      #expect(request.url?.path == "/v1/agents/a7/events")
      return (
        200,
        "event: heartbeat\ndata: {}\n\nevent: snapshot\ndata: {\"agentId\":\"a7\",\ndata: \"status\":\"running\"}\n\n"
      )
    }
    let received = Received()
    do { try await client.chatEvents("a7") { await received.append($0) } } catch is SSEClosedError {
    }
    #expect(await received.payloads == ["{\"agentId\":\"a7\",\n\"status\":\"running\"}"])
  }
}

actor Received {
  var payloads: [String] = []
  func append(_ payload: String) { payloads.append(payload) }
}
