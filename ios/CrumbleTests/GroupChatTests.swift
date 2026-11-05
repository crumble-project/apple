import apfelkern
import Foundation
import Testing

@testable import Crumble

private let trip = GroupChat(
  id: "trip", name: "Trip", memberIds: ["a1", "a2"], createdAt: "now", updatedAt: "now")

private let groupSnapshotFixture = """
  {"groupChat":{"id":"trip","name":"Trip","memberIds":["a1","a2"],"createdAt":"now","updatedAt":"now"},
   "activity":{"paused":false,"botTurns":0,"members":[
     {"agentId":"a1","status":"idle","error":null},{"agentId":"a2","status":"idle","error":null}]},
   "messages":[],"hasMore":false,"oldestEntryId":null,"updatedAt":1}
  """

private let groupEvent = ActivityEvent(
  eventId: "e", serverId: "s", createdAt: "now", type: "reply", agentId: "a1", agentName: "Ada",
  entryId: "trip:4", origin: "group", preview: "Booked.", groupId: "trip", groupName: "Trip")

@Test func groupAnswersNotifyWithTheGroupUnlessItIsOnScreen() {
  let away = notification(for: groupEvent, in: NotificationContext(appActive: true, route: .agent("a1")))
  #expect(away?.title == "Ada in Trip")
  #expect(away?.body == "Booked.")
  #expect(notification(for: groupEvent, in: NotificationContext(appActive: true, route: .group("trip"))) == nil)
  #expect(notification(for: groupEvent, in: NotificationContext(appActive: false, route: .group("trip"))) != nil)
}

@Test func aTappedGroupNotificationOpensTheGroupOnceBotsAreLoaded() {
  let payload = NotificationPayload(userInfo: [
    "type": "reply", "agentId": "gone", "agentName": "Ada", "eventId": "e", "serverId": "s",
    "origin": "group", "preview": "Booked.", "createdAt": ContractFixtures.timestamp,
    "entryId": NSNull(), "groupId": "trip", "groupName": "Trip"
  ])
  var router = NotificationTapRouter()
  router.queue(payload)
  #expect(router.resolve(serverID: "s", serverURL: nil, agentIDs: []) == nil)
  #expect(router.resolve(serverID: "s", serverURL: nil, agentIDs: ["a1"]) == .openGroup("trip"))
  #expect(router.resolve(serverID: "s", serverURL: nil, agentIDs: ["a1"]) == nil)
}

extension APIClientTests {
  @MainActor private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @MainActor private func openTrip(handler: @escaping (URLRequest) -> (Int, String)) async -> AppModel {
    let model = AppModel(
      client: StubProtocol.client { request in
        switch request.url?.path {
        case "/v1/group-chats/trip/chat": (200, groupSnapshotFixture)
        case "/v1/group-chats/trip/events": (200, "")
        default: handler(request)
        }
      })
    model.groupChats = [trip]
    model.selectGroup("trip")
    await waitFor { model.groupSnapshot != nil }
    return model
  }

  @MainActor @Test func groupMessageAppearsAtOnceAndTheSnapshotConfirmsIt() async {
    let model = await openTrip { request in
      request.url?.path == "/v1/group-chats/trip/messages"
        ? (201, #"{"requestId":"r","entryId":"trip:1"}"#) : (404, "")
    }
    defer { model.leaveGroup() }
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

    model.applyGroupSnapshot(
      GroupChatSnapshot(
        groupChat: trip,
        messages: [
          Message(
            id: "trip:1:0", entryId: "trip:1", role: "user", content: .string("Who packs the tent?"),
            requestId: requestID)
        ]))
    #expect(model.messages.count == 1)
    #expect(model.messages.first?.deliveryState == .confirmed)
  }

  @MainActor @Test func failedGroupMessageRestoresTheDraftAndRetriesWithTheSameRequest() async throws {
    var attempts = 0
    let model = await openTrip { request in
      guard request.url?.path == "/v1/group-chats/trip/messages" else { return (404, "") }
      attempts += 1
      return attempts == 1
        ? (500, #"{"error":"busy"}"#) : (201, #"{"requestId":"r","entryId":"trip:1"}"#)
    }
    defer { model.leaveGroup() }
    model.draft = "Retry me"
    await model.sendGroupMessage()?.value
    #expect(model.draft == "Retry me")
    let failed = try #require(model.messages.first { $0.deliveryState == .failed })
    model.draft = ""
    model.retryMessage(failed)
    await waitFor { attempts == 2 && !model.sending }
    let bodies = StubProtocol.requests
      .filter { $0.url?.path == "/v1/group-chats/trip/messages" }
      .compactMap(\.httpBody)
      .compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0)["requestId"]?.stringValue }
    #expect(bodies.count == 2)
    #expect(Set(bodies).count == 1)
  }

  @MainActor @Test func openingABotChatOrPanelClosesTheGroup() async {
    let model = await openTrip { request in
      request.url?.path == "/v1/agents/a1/chat" ? (200, ContractFixtures.snapshot("a1")) : (200, "[]")
    }
    defer { model.cancelStream() }
    model.selectAgent("a1")
    #expect(model.selectedGroupID.isEmpty)
    #expect(model.groupSnapshot == nil)
    #expect(model.route == .agent("a1"))

    model.selectGroup("trip")
    await waitFor { model.groupSnapshot != nil }
    model.openPanel(.tasks)
    #expect(model.selectedGroupID.isEmpty)
    #expect(model.groupStreamTask == nil)
    #expect(model.route == .tasks)
    model.navigate(to: .group("trip"))
    #expect(model.selectedGroupID == "trip")
    model.leaveGroup()
  }

  @MainActor @Test func groupStreamStopsInTheBackgroundAndCatchesUpOnReturn() async {
    let streamed = groupSnapshotFixture.replacingOccurrences(
      of: #""messages":[]"#,
      with: #""messages":[{"id":"trip:1:0","entryId":"trip:1","role":"assistant","content":"From the stream","#
        + #""origin":{"kind":"bot","agentId":"a1","name":"Ada"}}]"#
    ).replacingOccurrences(of: "\n", with: "")
    let model = AppModel(
      client: StubProtocol.client { request in
        switch request.url?.path {
        case "/v1/group-chats/trip/chat": (200, groupSnapshotFixture)
        case "/v1/group-chats/trip/events":
          (200, "event: snapshot\ndata: " + streamed + "\n\n")
        case "/v1/group-chats":
          (200, #"[{"id":"trip","name":"Trip","memberIds":["a1","a2"],"createdAt":"now","updatedAt":"now"}]"#)
        default: (404, "")
        }
      })
    defer { model.leaveGroup() }
    model.groupChats = [trip]
    model.selectGroup("trip")
    await waitFor { model.messages.contains { $0.text == "From the stream" } }
    model.suspendStreams()
    #expect(model.groupStreamTask == nil)
    model.messages = []
    model.resumeStreams()
    await waitFor { model.messages.contains { $0.text == "From the stream" } }
    #expect(model.messages.map(\.text) == ["From the stream"])
    #expect(model.route == .group("trip"))
  }

  @MainActor @Test func aSlowGroupCreationDoesNotTakeOverNewerNavigation() async {
    let created = #"{"id":"trip","name":"Trip","memberIds":["a1","a2"],"createdAt":"now","updatedAt":"now"}"#
    let model = AppModel(
      client: StubProtocol.client { request in
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/v1/group-chats"):
          Thread.sleep(forTimeInterval: 0.3)
          return (201, created)
        case (_, "/v1/agents/a1/chat"): return (200, ContractFixtures.snapshot("a1"))
        default: return (404, "")
        }
      })
    defer { model.cancelStream() }
    model.agents = [Agent(id: "a1", name: "Ada"), Agent(id: "a2", name: "Grace")]
    model.saveGroup(GroupDraft(name: "Trip", memberIDs: ["a1", "a2"]))
    #expect(model.groupChats.first?.id.hasPrefix("local:") == true)
    model.selectAgent("a1")
    model.draft = "Still typing"
    await waitFor { model.groupChats.contains { $0.id == "trip" } }
    #expect(model.groupChats.map(\.id) == ["trip"])
    #expect(model.route == .agent("a1"))
    #expect(model.draft == "Still typing")
  }

  @MainActor @Test func aFailedGroupCreationRestoresTheDraft() async {
    let model = AppModel(client: StubProtocol.client { _ in (500, #"{"error":"busy"}"#) })
    model.saveGroup(GroupDraft(name: "Trip", memberIDs: ["a1", "a2"]))
    #expect(model.groupChats.count == 1)
    #expect(model.groupDraft == nil)
    await waitFor { model.groupDraft != nil }
    #expect(model.groupChats.isEmpty)
    #expect(model.groupDraft?.name == "Trip")
  }

  @MainActor @Test func aFailedDeletionReopensTheGroup() async {
    let model = await openTrip { request in
      request.httpMethod == "DELETE" ? (500, #"{"error":"busy"}"#) : (404, "")
    }
    defer { model.leaveGroup() }
    model.deleteGroup("trip")
    #expect(model.groupChats.isEmpty)
    #expect(model.route == nil)
    await waitFor { model.errorText.contains("busy") && model.groupSnapshot != nil }
    #expect(model.groupChats.map(\.id) == ["trip"])
    #expect(model.route == .group("trip"))
  }
}
