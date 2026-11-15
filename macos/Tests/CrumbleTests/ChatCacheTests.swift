import apfelkern
import Foundation
import Testing

@testable import Crumble

private func newestChatPage(overlapping: Bool = true) throws -> String {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(chatFixture().utf8))
    guard case .object(var fields) = value else { throw CancellationError() }
    fields["messages"] = .array([.object([
        "id": .string("a1:4:0"), "entryId": .string("a1:4"), "role": .string("assistant"),
        "content": .string("Newest reply"), "replyReferences": .array([])
    ])])
    if overlapping, case .array(let messages) = fields["messages"] {
        fields["messages"] = .array([.object([
            "id": .string("a1:2:0"), "entryId": .string("a1:2"), "role": .string("assistant"),
            "content": .string("Recent"), "replyReferences": .array([])
        ])] + messages)
    }
    fields["hasMore"] = .bool(true)
    fields["oldestEntryId"] = .string(overlapping ? "a1:2" : "a1:4")
    return JSONValue.object(fields).prettyPrinted
}

extension APIClientTests {
    @MainActor @Test func cachedPaginationWaitsForTheFreshSnapshot() async throws {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        defer { model.cancelStream(preservingWork: false) }
        model.selectedAgentID = "a1"
        model.applySnapshot(ChatSnapshot(messages: [
            Message(id: "a1:1:0", entryId: "a1:1", role: "user", content: .string("Cached"))
        ], agentId: "a1"))
        model.hasMore = true
        model.oldestEntryID = "a1:1"
        model.leaveBotChat()
        let historyPath = "/v1/agents/a1/chat/history"
        await controller.hold("/v1/agents/a1/chat")
        await controller.hold(historyPath)
        model.selectAgent("a1")
        #expect(await controller.waitForHeld("/v1/agents/a1/chat"))
        model.loadOlder()
        let started = model.loadingOlder
        #expect(!started)
        if started { #expect(await controller.waitForHeld(historyPath)) }
        await controller.release("/v1/agents/a1/chat", body: try newestChatPage(overlapping: false))
        for _ in 0..<200 where model.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.snapshot?.agentId == "a1")
        await controller.release(historyPath, body:
            #"{"messages":[{"id":"a1:0:0","entryId":"a1:0","role":"user","#
            + #""content":"Detached older","replyReferences":[]}],"hasMore":false,"oldestEntryId":"a1:0"}"#)
        for _ in 0..<200 where model.loadingOlder { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.messages.map(\.id) == ["a1:4:0"])
        #expect(model.hasMore == true)
        #expect(model.oldestEntryID == "a1:4")
    }

    @MainActor @Test func aDisjointSnapshotRestartsPaginationWithoutKeepingAGap() async throws {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        defer { model.cancelStream(preservingWork: false) }
        model.selectedAgentID = "a1"
        model.route = .agent("a1")
        model.applySnapshot(ChatSnapshot(messages: [
            Message(id: "a1:1:0", entryId: "a1:1", role: "user", content: .string("Earlier"))
        ], agentId: "a1"))
        model.oldestEntryID = "a1:1"
        model.leaveBotChat()
        await controller.hold("/v1/agents/a1/chat")
        model.selectAgent("a1")
        #expect(model.messages.first?.id == "a1:1:0")
        #expect(await controller.waitForHeld("/v1/agents/a1/chat"))
        await controller.release("/v1/agents/a1/chat", body: try newestChatPage(overlapping: false))
        for _ in 0..<200 where model.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.snapshot?.agentId == "a1")
        #expect(model.messages.map(\.id) == ["a1:4:0"])
        #expect(model.hasMore)
        #expect(model.oldestEntryID == "a1:4")
    }

    @MainActor @Test func cachedChatsAreClearedWhenTheConnectionChanges() {
        let client = StubProtocol.client { _ in (404, "") }
        let model = AppModel(client: client)
        model.selectedAgentID = "a1"
        model.applySnapshot(ChatSnapshot(
            messages: [Message(id: "a1:1:0", role: "user", content: .string("Private"))], agentId: "a1"))
        model.rememberSelectedChat()
        #expect(model.chatCache["a1"]?.messages.first?.text == "Private")

        model.applyConnection(APIClient(baseURL: client.baseURL, token: "next", session: client.session))
        #expect(model.chatCache.isEmpty)
        #expect(model.messages.isEmpty)
    }

    @MainActor @Test(arguments: [false, true])
    func cachedChatsKeepTheirEarlierPagesAndPendingMessages(hasMore: Bool) async throws {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        defer { model.cancelStream(preservingWork: false) }
        model.selectedAgentID = "a1"
        model.route = .agent("a1")
        let earlier = Message(id: "a1:1:0", entryId: "a1:1", role: "user", content: .string("Earlier"))
        let recent = Message(id: "a1:2:0", entryId: "a1:2", role: "assistant", content: .string("Recent"))
        model.applySnapshot(ChatSnapshot(messages: [earlier, recent], agentId: "a1"))
        model.hasMore = hasMore
        model.oldestEntryID = "a1:1"
        let pending = model.delivery.stage(
            .init(content: "Pending", replyTo: "", attachments: []), botID: "a1", requestID: "pending")
        model.messages.append(pending)
        model.leaveBotChat()
        #expect(model.chatCache["a1"]?.messages.map(\.id) == [earlier.id, recent.id])

        await controller.hold("/v1/agents/a1/chat")
        model.selectAgent("a1")
        #expect(model.snapshot == nil)
        #expect(model.messages.map(\.id) == [earlier.id, recent.id, pending.id])
        #expect(model.hasMore == hasMore)
        #expect(model.oldestEntryID == "a1:1")
        #expect(await controller.waitForHeld("/v1/agents/a1/chat"))
        await controller.release("/v1/agents/a1/chat", body: try newestChatPage())
        for _ in 0..<200 where model.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.snapshot?.agentId == "a1")
        #expect(model.messages.map(\.id) == [earlier.id, recent.id, "a1:4:0", pending.id])
        #expect(model.hasMore == hasMore)
        #expect(model.oldestEntryID == "a1:1")
    }
}
