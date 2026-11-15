import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let references = #"[{"eventId":"text-event","surface":{"kind":"text"}},"#
  + #"{"eventId":"tool-event","surface":{"kind":"tool-card","toolCallId":"t1"}},"#
  + #"{"eventId":"held-event","surface":{"kind":"held-action","actionId":"h1"}},"#
  + #"{"eventId":"text-event","surface":{"kind":"text"}}]"#

private func transcriptMessage(_ content: String = "Answer", references: String = references) -> String {
  #"{"id":"a1:1:0","entryId":"a1:1","role":"assistant","content":"\#(content)","replyReferences":\#(references)}"#
}

private func chatSnapshot(_ content: String = "Answer", references: String = references) -> String {
  #"{"agentId":"a1","status":"idle","working":"idle","partial":"","updatedAt":0,"error":null,"hasMore":false,"#
    + #""oldestEntryId":null,"conversationId":"c1","#
    + #""conversation":{"id":"c1","agentId":"a1","title":"Chat","createdAt":"now","updatedAt":"now"},"#
    + #""messages":[\#(transcriptMessage(content, references: references))]}"#
}

private let groupSnapshot = #"{"groupChat":{"id":"g1","name":"Trip","memberIds":["a1","a2"],"#
  + #""createdAt":"now","updatedAt":"now"},"activity":{"paused":false,"botTurns":0,"members":[]},"#
  + #""messages":[{"id":"g1:1:0","entryId":"g1:1","role":"assistant","content":"Packed","#
  + #""origin":{"kind":"bot","agentId":"a1","name":"Ada"},"#
  + #""replyReferences":[{"eventId":"group-event","surface":{"kind":"text"}}]}],"hasMore":false,"#
  + #""oldestEntryId":null,"updatedAt":1}"#

@Test func referencesSurviveHistoryTheStreamAndAGroupSnapshot() async throws {
  let expected = [
    ReplyReference(eventId: "text-event", surface: .text),
    ReplyReference(eventId: "tool-event", surface: .toolCard("t1")),
    ReplyReference(eventId: "held-event", surface: .heldAction("h1")),
    ReplyReference(eventId: "text-event", surface: .text)
  ]
  let streamed = try JSONDecoder().decode(ChatSnapshot.self, from: Data(chatSnapshot().utf8))
  #expect(streamed.messages?.first?.replyReferences == expected)
  let group = try JSONDecoder().decode(GroupChatSnapshot.self, from: Data(groupSnapshot.utf8))
  #expect(group.messages.first?.replyReferences == [ReplyReference(eventId: "group-event", surface: .text)])
  try await withClient(handler: { request in
    let body = request.url?.path.hasSuffix("/history") == true
      ? #"{"messages":[\#(transcriptMessage())],"hasMore":false,"oldestEntryId":null}"# : chatSnapshot()
    return StubResponse(body: Data(body.utf8))
  }, test: { client in
    #expect(try await client.chat("a1").messages?.first?.replyReferences == expected)
    let page = try await client.chatHistory("a1", before: "", limit: 5)
    #expect(page.messages?.first?.replyReferences == expected)
  })
  let message = try #require(streamed.messages?.first)
  let saved = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
  #expect(saved.replyReferences == expected)
}

@Test func onlyTheExactSurfaceAcknowledgesItsEvents() throws {
  let message = try #require(
    try JSONDecoder().decode(ChatSnapshot.self, from: Data(chatSnapshot().utf8)).messages?.first)
  #expect(message.attentionEventIDs(for: .text) == ["text-event"])
  #expect(message.attentionEventIDs(for: .toolCard("t1")) == ["tool-event"])
  #expect(message.attentionEventIDs(for: .heldAction("h1")) == ["held-event"])
  #expect(message.attentionEventIDs(for: .toolCard("t2")).isEmpty)
  #expect(message.attentionEventIDs(for: .heldAction("t1")).isEmpty)
  #expect(message.showsReplyText)

  let citationsOnly = Message(
    id: "m", role: "assistant", content: .string("[a](https://example.com)"),
    presentation: MessagePresentation(citations: [], text: " \n"))
  #expect(!citationsOnly.showsReplyText)
  #expect(!Message(id: "m", role: "user", content: .string("Hi")).showsReplyText)
}

@MainActor @Test func cardsNameTheirSurfaceAndWaitForTheirBoards() throws {
  let held = Message(
    id: "m1", role: "event", kind: HeldActionEvent.messageKind, heldAction: HeldActionEvent(id: "h1", job: "j"))
  let secret = Message(
    id: "m2", role: "toolResult", toolName: BotSecretKind.credential.toolName, toolCallId: "t1",
    toolDetails: .object(["name": .string("TOKEN")]))
  let unnamed = Message(
    id: "m3", role: "toolResult", toolName: BotSecretKind.credential.toolName,
    toolDetails: .object(["name": .string("TOKEN")]))
  func card(_ message: Message) -> (surface: ReplySurface, ready: Bool)? {
    message.replyCard(
      heldActions: HeldActionBoard(), botRequests: BotRequestBoard(), callRequests: CallRequestBoard(),
      botSecrets: BotSecretBoard())
  }
  #expect(card(held)?.surface == .heldAction("h1"))
  #expect(card(held)?.ready == false)
  #expect(card(secret)?.surface == .toolCard("t1"))
  #expect(card(secret)?.ready == false)
  #expect(card(unnamed) == nil)
  #expect(card(Message(id: "m4", role: "assistant", content: .string("Hi"))) == nil)
}

@Test func aSurfaceCountsOnlyWithAreaInsideTheViewport() {
  let viewport = CGRect(x: 0, y: 100, width: 300, height: 300)
  let content = CGRect(x: 10, y: 150, width: 200, height: 50)
  #expect(replySurfaceVisible(ready: true, frame: content, viewport: viewport))
  #expect(!replySurfaceVisible(ready: false, frame: content, viewport: viewport))
  #expect(!replySurfaceVisible(ready: true, frame: .zero, viewport: viewport))
  #expect(!replySurfaceVisible(ready: true, frame: content, viewport: .zero))
  #expect(!replySurfaceVisible(ready: true, frame: CGRect(x: 10, y: 0, width: 200, height: 100), viewport: viewport))
  #expect(!replySurfaceVisible(ready: true, frame: CGRect(x: 10, y: 400, width: 200, height: 9), viewport: viewport))
  #expect(replySurfaceVisible(ready: true, frame: CGRect(x: 10, y: 0, width: 200, height: 101), viewport: viewport))

  var surfaces = ReplySurfaces()
  let container = CGSize(width: 300, height: 400)
  surfaces.set("a", of: .bot("a1"), frame: content, container: container, eventIDs: ["e1", "e2"], ready: true)
  surfaces.set("b", of: .bot("a1"), frame: content, container: container, eventIDs: ["e2"], ready: true)
  surfaces.set("c", of: .group("a1"), frame: content, container: container, eventIDs: ["g"], ready: true)
  #expect(Set(surfaces.visibleEventIDs(in: .bot("a1"))) == ["e1", "e2"])
  #expect(surfaces.visibleEventIDs(in: .bot("a1")).count == 2)
  #expect(surfaces.visibleEventIDs(in: .group("a1")) == ["g"])
  surfaces.setInsets(top: 0, bottom: 260)
  #expect(surfaces.visibleEventIDs(in: .bot("a1")).isEmpty)
  surfaces.setInsets(top: 0, bottom: 0)
  surfaces.keep(only: .group("a1"))
  #expect(surfaces.visibleEventIDs(in: .bot("a1")).isEmpty)
}

@Test func routesAndRepliesNameTheirChat() {
  #expect(Route.agent("a1").attentionChat == .bot("a1"))
  #expect(Route.group("g1").attentionChat == .group("g1"))
  #expect(Route.skills.attentionChat == nil)
  let reply = ActivityEvent(type: "reply", agentId: "a1", agentName: "Ada")
  #expect(reply.attentionChat == .bot("a1"))
  var groupReply = reply
  groupReply.groupId = "g1"
  #expect(groupReply.attentionChat == .group("g1"))
}

// MARK: Reloading references after a live reply

/// The least a chat needs to host group chats, applying bot snapshots by merge as the apps do.
@MainActor
private final class Host: GroupChatHost {
  var client: APIClient?
  var generation = 0
  var mutationRevision = 0
  var pendingMutations: Set<String> = []
  var route: Route?
  var selectedAgentID = ""
  var selectionVersion = 0
  var groupChats: [GroupChat] = []
  var selectedGroupID = ""
  var groupSnapshot: GroupChatSnapshot?
  var groupDraft: GroupDraft?
  var groupStreamTask: Task<Void, Never>?
  var composerDrafts = ComposerDrafts()
  var groupArrivals = 0
  var messages: [Message] = []
  var hasMore = false
  var oldestEntryID = ""
  var loadingOlder = false
  var draft = ""
  var attachments: [PendingAttachment] = []
  var replyTo: Message?
  var sending = false
  var draftRequestID = ""
  var failedDraft = ""
  var failedReplyTo = ""
  var failedAttachments: [UUID] = []
  var delivery = BotChatDelivery()
  var deletedFiles = DeletedFiles()
  var errorText = ""
  var streamStatus = ""
  var snapshotRevision = 0

  init(client: APIClient) {
    self.client = client
  }

  func leaveBotChat() { selectedAgentID = "" }

  func applySnapshot(_ incoming: ChatSnapshot) {
    snapshotRevision += 1
    messages = mergeMessages(messages, incoming.messages ?? [])
  }

  func request(_ work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?) {}

  func optimisticMutation(
    key: String, update: () -> Void, rollback: @escaping @MainActor () -> Void,
    work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
  ) {}

  func showNotice(_ text: String) {}
}

@MainActor
private func eventually(_ done: () -> Bool) async throws {
  for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
  #expect(done())
}

private let reply = ActivityEvent(eventId: "text-event", type: "reply", agentId: "a1", agentName: "Ada")

private final class Reads: Sendable {
  let count = Mutex(0)
}

private func reloads(_ reads: Reads) -> ContractURLProtocol.Handler {
  { request in
    reads.count.withLock { $0 += 1 }
    let body = request.url?.path.contains("/group-chats/") == true ? groupSnapshot : chatSnapshot("Reloaded")
    return StubResponse(body: Data(body.utf8), delay: 0.15)
  }
}

@MainActor @Test func aLiveReplyReloadsTheBotChatOnScreenUnlessSomethingNewerLandsFirst() async throws {
  let reads = Reads()
  try await withClient(handler: reloads(reads), test: { client in
    let host = Host(client: client)
    host.route = .agent("a1")
    host.selectedAgentID = "a1"
    host.draft = "Keep this"
    host.refreshReplyReferences(after: reply, active: false)
    var other = reply
    other.agentId = "a2"
    host.refreshReplyReferences(after: other, active: true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(reads.count.withLock { $0 } == 0)

    host.refreshReplyReferences(after: reply, active: true)
    host.applySnapshot(try JSONDecoder().decode(ChatSnapshot.self, from: Data(chatSnapshot("Streamed").utf8)))
    try await Task.sleep(for: .milliseconds(300))
    #expect(reads.count.withLock { $0 } == 1)
    #expect(host.messages.map(\.text) == ["Streamed"])

    host.refreshReplyReferences(after: reply, active: true)
    host.selectionVersion += 1
    try await Task.sleep(for: .milliseconds(300))
    #expect(host.messages.map(\.text) == ["Streamed"])

    host.refreshReplyReferences(after: reply, active: true)
    try await eventually { host.messages.map(\.text) == ["Reloaded"] }
    #expect(host.messages.first?.attentionEventIDs(for: .text) == ["text-event"])
    #expect(host.draft == "Keep this")
  })
}

@MainActor @Test func aLiveGroupReplyReloadsTheGroupOnScreenAndKeepsTheDraft() async throws {
  try await withClient(handler: reloads(Reads()), test: { client in
    let host = Host(client: client)
    host.selectedGroupID = "g1"
    host.route = .group("g1")
    host.draft = "Keep this"
    var groupReply = reply
    groupReply.groupId = "g1"
    host.refreshReplyReferences(after: groupReply, active: true)
    try await eventually { host.messages.contains { $0.id == "g1:1:0" } }
    #expect(host.messages.first { $0.id == "g1:1:0" }?.attentionEventIDs(for: .text) == ["group-event"])
    #expect(host.draft == "Keep this")
  })
}
