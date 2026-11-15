import apfelkern
import Foundation
import Testing

@testable import Crumble

private func attentionChat(_ request: URLRequest) -> JSONValue? {
  guard let body = request.httpBody,
    case .object(let fields) = try? JSONDecoder().decode(JSONValue.self, from: body)
  else { return nil }
  return fields["chat"]
}

private func reportedChat(_ kind: String, _ id: String) -> JSONValue {
  .object(["kind": .string(kind), "id": .string(id)])
}

private let referencedReply = #"{"agentId":"a1","status":"idle","working":"idle","partial":"","updatedAt":0,"#
  + #""error":null,"hasMore":false,"oldestEntryId":null,"conversationId":"c1","#
  + #""conversation":{"id":"c1","agentId":"a1","title":"Chat","createdAt":"now","updatedAt":"now"},"#
  + #""messages":[{"id":"a1:2:0","entryId":"a1:2","role":"assistant","content":"Done","#
  + #""replyReferences":[{"eventId":"reply-event","surface":{"kind":"text"}}]}]}"#

@MainActor
private func eventually(_ done: () -> Bool) async -> Bool {
  for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
  return done()
}

extension APIClientTests {
  @MainActor @Test func theActiveSceneReportsItsChatWithoutPushAndClearsBeforeSignOut() async throws {
    let client = StubProtocol.client(token: "session") { _ in (204, "") }
    let model = AppModel(client: client)
    let presence = {
      StubProtocol.requests.filter { $0.url?.path.hasPrefix("/v1/chat-attention/views/") == true }
    }
    model.route = .agent("a1")
    model.setSceneActive(true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(presence().isEmpty)

    // The chat's view mounts once its transcript shows.
    model.chatAttention.mount(.bot("a1"))
    #expect(await eventually { presence().count == 1 })
    #expect(attentionChat(presence()[0]) == reportedChat("bot", "a1"))

    model.setSceneActive(false)
    #expect(await eventually { presence().count == 2 })
    #expect(attentionChat(presence()[1]) == .null)

    model.setSceneActive(true)
    model.route = .group("g1")
    model.chatAttention.mount(.group("g1"))
    #expect(await eventually { presence().last.flatMap(attentionChat) == reportedChat("group", "g1") })
    #expect(!StubProtocol.requests.contains { $0.url?.path.hasPrefix("/v1/push") == true })

    model.signOut()
    #expect(await eventually { model.client?.token.isEmpty == true })
    let last = try #require(presence().last)
    #expect(attentionChat(last) == .null)
    #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer session")
  }

  @MainActor @Test func aLiveReplyReloadsTheOpenChatAndKeepsTheDraft() async throws {
    let client = StubProtocol.client(token: "session") { request in
      request.url?.path == "/v1/agents/a1/chat" ? (200, referencedReply) : (204, "")
    }
    let model = AppModel(client: client)
    let reads = { StubProtocol.requests.filter { $0.url?.path == "/v1/agents/a1/chat" }.count }
    model.updateSelectedAgent("a1")
    model.route = .agent("a1")
    model.messages = [Message(id: "a1:1:0", entryId: "a1:1", role: "user", content: .string("Hi"))]
    model.draft = "Keep this"
    let reply = ActivityEvent(eventId: "reply-event", type: "reply", agentId: "a1", agentName: "Atlas")

    model.handleActivity(reply)
    try await Task.sleep(for: .milliseconds(50))
    #expect(reads() == 0)

    model.setSceneActive(true)
    model.handleActivity(reply)
    #expect(await eventually { model.messages.count == 2 })
    #expect(reads() == 1)
    #expect(model.messages.last?.attentionEventIDs(for: .text) == ["reply-event"])
    #expect(model.messages.first?.text == "Hi")
    #expect(model.draft == "Keep this")
  }
}
