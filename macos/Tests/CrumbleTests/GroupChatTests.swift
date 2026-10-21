import apfelkern
import Foundation
import Testing

@testable import Crumble

private let trip = GroupChat(id: "trip", name: "Trip", memberIds: ["a1", "a2"], createdAt: "now", updatedAt: "now")

private let groupSnapshotFixture = """
    {"groupChat":{"id":"trip","name":"Trip","memberIds":["a1","a2"],"createdAt":"now","updatedAt":"now"},
     "activity":{"paused":false,"botTurns":0,"members":[
       {"agentId":"a1","status":"idle","error":null},{"agentId":"a2","status":"idle","error":null}]},
     "messages":[],"hasMore":false,"oldestEntryId":null,"updatedAt":1}
    """

@Test func groupRowsAttachReactionsAndShowWhoIsWorking() {
    let agents = [Agent(id: "a1", name: "Ada"), Agent(id: "a2", name: "Grace")]
    let messages = [
        Message(id: "trip:1:0", entryId: "trip:1", role: "user", content: .string("Pack light")),
        Message(
            id: "trip:2:0", entryId: "trip:2", role: "toolResult", content: .string("Reacted 👍"),
            replyTo: "trip:1", origin: MessageOrigin(kind: "bot", name: "Ada", agentId: "a1"),
            toolName: "react", toolDetails: .object(["emoji": .string("👍")])),
        Message(
            id: "trip:3:0", entryId: "trip:3", role: "assistant", content: .string("Tent packed."),
            origin: MessageOrigin(kind: "bot", name: "Grace", agentId: "a2"))
    ]
    let snapshot = GroupChatSnapshot(
        groupChat: trip,
        activity: GroupActivity(paused: true, botTurns: 8, members: [
            GroupMemberActivity(agentId: "a1", status: .running),
            GroupMemberActivity(agentId: "a2", status: .idle, error: "Provider unavailable")
        ]))

    let rows = GroupChatRow.rows(messages: messages, snapshot: snapshot, agents: agents, hasMore: false)
    let ids = rows.map(\.id)

    #expect(ids.contains("trip:1:0") && ids.contains("trip:3:0"))
    #expect(!ids.contains("trip:2:0"))
    guard case .message(_, let reactions)? = rows.first(where: { $0.id == "trip:1:0" }) else {
        Issue.record("The owner's message is missing")
        return
    }
    #expect(reactions == [Reaction.Mark(emoji: "👍", from: "Ada")])
    #expect(ids.suffix(3) == ["working", "failure:a2", "paused"])
}

@Test func groupAnswersNotifyWithTheGroupUnlessItIsOnScreen() {
    let event = ActivityEvent(
        eventId: "e", serverId: "s", createdAt: "now", type: "reply", agentId: "a1", agentName: "Ada",
        entryId: "trip:4", origin: "group", preview: "Booked.", groupId: "trip", groupName: "Trip")

    let away = notification(for: event, in: NotificationContext(windowOnScreen: true, route: .agent("a1")))
    #expect(away?.title == "Ada in Trip")
    #expect(away?.body == "Booked.")
    #expect(notification(for: event, in: NotificationContext(windowOnScreen: true, route: .group("trip"))) == nil)
    #expect(NotificationTarget(serverURL: "x", agentId: "a1", groupId: "trip").route == .group("trip"))
    #expect(NotificationTarget(serverURL: "x", agentId: "a1").route == .agent("a1"))
}

@Test func memorySourcesReadAsPlainLabels() {
    #expect(memorySourceLabel(nil) == nil)
    #expect(memorySourceLabel(MemorySource(kind: "group", name: "Trip", groupId: "trip")) == "From the group chat Trip")
    #expect(memorySourceLabel(MemorySource(kind: "task", name: "Morning brief")) == "From the task Morning brief")
    #expect(memorySourceLabel(MemorySource(kind: "owner")) == "Added by you")
}

@Test func groupDraftsNeedANameAndTwoToSixBots() {
    #expect(!GroupDraft(name: "Trip", memberIDs: ["a1"]).isValid)
    #expect(!GroupDraft(name: " ", memberIDs: ["a1", "a2"]).isValid)
    #expect(GroupDraft(name: "Trip", memberIDs: ["a1", "a2"]).isValid)
    #expect(!GroupDraft(name: "Trip", memberIDs: (1...7).map { "a\($0)" }).isValid)
}

extension APIClientTests {
    @MainActor private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor @Test func groupMessageAppearsAtOnceAndTheSnapshotConfirmsIt() async {
        let model = AppModel(client: StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/group-chats/trip/chat": (200, groupSnapshotFixture)
            case "/v1/group-chats/trip/events": (200, "")
            case "/v1/group-chats/trip/messages": (201, #"{"requestId":"r","entryId":"trip:1"}"#)
            default: (404, "")
            }
        })
        defer { model.leaveGroup() }
        model.groupChats = [trip]
        model.selectGroup("trip")
        await waitFor { model.groupSnapshot != nil }
        #expect(model.route == .group("trip"))
        #expect(model.selectedAgentID.isEmpty)

        model.draft = "Who packs the tent?"
        model.sendGroupMessage()
        let optimistic = model.messages.first { $0.text == "Who packs the tent?" }
        #expect(optimistic?.deliveryState == .sending)
        let requestID = optimistic?.requestId
        await waitFor {
            StubProtocol.requests.contains { $0.url?.path == "/v1/group-chats/trip/messages" }
        }

        model.applyGroupSnapshot(GroupChatSnapshot(
            groupChat: trip,
            messages: [Message(
                id: "trip:1:0", entryId: "trip:1", role: "user", content: .string("Who packs the tent?"),
                requestId: requestID)]))
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.deliveryState == .confirmed)
    }

    @MainActor @Test func openingABotChatClosesTheGroup() async {
        let model = AppModel(client: StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/group-chats/trip/chat": (200, groupSnapshotFixture)
            case "/v1/group-chats/trip/events": (200, "")
            case "/v1/agents/a1/chat": (200, chatFixture())
            default: (404, "")
            }
        })
        defer {
            model.leaveGroup()
            model.cancelStream(preservingWork: false)
        }
        model.groupChats = [trip]
        model.selectGroup("trip")
        await waitFor { model.groupSnapshot != nil }
        model.selectAgent("a1")
        #expect(model.selectedGroupID.isEmpty)
        #expect(model.groupSnapshot == nil)
        #expect(model.route == .agent("a1"))
    }

    @MainActor @Test func groupStreamSnapshotsReachTheTranscript() async {
        let streamed = groupSnapshotFixture.replacingOccurrences(
            of: #""messages":[]"#,
            with: #""messages":[{"id":"trip:1:0","entryId":"trip:1","role":"assistant","content":"From the stream","#
                + #""origin":{"kind":"bot","agentId":"a1","name":"Ada"}}]"#
        ).replacingOccurrences(of: "\n", with: "")
        let model = AppModel(client: StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/group-chats/trip/chat": (200, groupSnapshotFixture)
            case "/v1/group-chats/trip/events": (200, "event: snapshot\ndata: " + streamed + "\n\n")
            default: (404, "")
            }
        })
        defer { model.leaveGroup() }
        model.groupChats = [trip]
        model.selectGroup("trip")
        await waitFor { model.messages.contains { $0.text == "From the stream" } }
        #expect(model.messages.map(\.text) == ["From the stream"])
    }

    @MainActor @Test func aSlowGroupCreationDoesNotTakeOverNewerNavigation() async {
        let created = #"{"id":"trip","name":"Trip","memberIds":["a1","a2"],"createdAt":"now","updatedAt":"now"}"#
        let model = AppModel(client: StubProtocol.client { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/group-chats"):
                Thread.sleep(forTimeInterval: 0.3)
                return (201, created)
            case (_, "/v1/agents/a1/chat"): return (200, chatFixture())
            default: return (404, "")
            }
        })
        defer { model.cancelStream(preservingWork: false) }
        model.agents = [Agent(id: "a1", name: "Ada"), Agent(id: "a2", name: "Grace")]
        model.saveGroup(GroupDraft(name: "Trip", memberIDs: ["a1", "a2"]))
        model.selectAgent("a1")
        model.draft = "Still typing"
        await waitFor { model.groupChats.contains { $0.id == "trip" } }
        #expect(model.groupChats.map(\.id) == ["trip"])
        #expect(model.route == .agent("a1"))
        #expect(model.draft == "Still typing")
    }
}
