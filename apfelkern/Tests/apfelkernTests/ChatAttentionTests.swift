import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import apfelkern

/// A request to the chat-attention API, as the stub server received it.
private struct Sent: Sendable {
  var method: String
  var path: String
  var token: String
  var body: JSONValue

  init(_ request: URLRequest) {
    method = request.httpMethod ?? ""
    path = request.url?.path ?? ""
    token = request.value(forHTTPHeaderField: "Authorization") ?? ""
    body = (try? requestJSON(request)) ?? .null
  }

  var view: String { path.components(separatedBy: "/").last ?? "" }
  var chat: JSONValue? { if case .object(let fields) = body { fields["chat"] } else { nil } }
  var chatID: String? {
    if case .object(let chat)? = chat, case .string(let id)? = chat["id"] { id } else { nil }
  }
  var kind: String? {
    if case .object(let chat)? = chat, case .string(let kind)? = chat["kind"] { kind } else { nil }
  }
  var eventIDs: [String] {
    guard case .object(let fields) = body, case .array(let ids)? = fields["eventIds"] else { return [] }
    return ids.compactMap { if case .string(let id) = $0 { id } else { nil } }
  }
}

private let noContent = StubResponse(status: 204, body: Data())

private func failure(_ status: Int) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"no"}"#.utf8))
}

private final class AttentionServer: Sendable {
  private let sent = Mutex<[Sent]>([])
  private let reply = Mutex<@Sendable (Sent) -> StubResponse>({ _ in noContent })

  var handler: ContractURLProtocol.Handler {
    { [self] request in
      let request = Sent(request)
      sent.withLock { $0.append(request) }
      return reply.withLock { $0 }(request)
    }
  }

  func respond(_ reply: @escaping @Sendable (Sent) -> StubResponse) {
    self.reply.withLock { $0 = reply }
  }

  var all: [Sent] { sent.withLock { $0 } }
  var presence: [Sent] { all.filter { $0.method == "PUT" } }
  var seen: [Sent] { all.filter { $0.method == "POST" } }
}

private let timing = ChatAttention.Timing(
  heartbeat: .milliseconds(250), batchDelay: .milliseconds(10), retry: .milliseconds(20),
  maxRetry: .milliseconds(40), clearTimeout: .milliseconds(300))
private let bot = ChatAttentionChat.bot("a1")
private let group = ChatAttentionChat.group("g1")

@MainActor
private func eventually(_ done: () -> Bool) async throws {
  for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
  #expect(done())
}

/// Lets anything still due land, for checks that nothing more was sent.
private func pause(_ milliseconds: Int = 120) async throws {
  try await Task.sleep(for: .milliseconds(milliseconds))
}

extension ChatAttention {
  /// A surface that's ready and inside a 100-point viewport.
  fileprivate func show(_ eventIDs: [String], in chat: ChatAttentionChat, key: String = "s") {
    setSurface(
      key, of: chat, frame: CGRect(x: 0, y: 10, width: 50, height: 20), container: CGSize(width: 100, height: 100),
      eventIDs: eventIDs, ready: true)
  }
}

private func other(_ client: APIClient, token: String) -> APIClient {
  APIClient(baseURL: client.baseURL, token: token, session: client.session)
}

@MainActor @Test func presenceNeedsAnActiveRouteAndItsMountedChatButNoPushRegistration() async throws {
  let server = AttentionServer()
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    attention.update(client: client, active: true, route: bot)
    attention.mount(group)
    try await pause(60)
    #expect(server.all.isEmpty)

    attention.mount(bot)
    try await eventually { server.presence.count == 1 }
    #expect(server.presence[0].body == .object(["chat": .object(["kind": .string("bot"), "id": .string("a1")])]))
    #expect(server.presence[0].path == "/prefix/v1/chat-attention/views/\(attention.viewID)")

    attention.update(client: client, active: false, route: bot)
    try await eventually { server.presence.count == 2 }
    #expect(server.presence[1].body == .object(["chat": .null]))

    attention.update(client: client, active: true, route: group)
    attention.mount(group)
    try await eventually { server.presence.last?.kind == "group" }
    #expect(server.presence.last?.chatID == "g1")

    attention.update(client: other(client, token: " "), active: true, route: group)
    try await eventually { server.presence.last?.chat == .null }
    try await pause()
    #expect(server.all.allSatisfy { $0.path.hasPrefix("/prefix/v1/chat-attention/views/") })
  })
}

@MainActor @Test func aRefreshInFlightCollapsesBehindTheClearAndTheHeartbeatStopsWithIt() async throws {
  let server = AttentionServer()
  server.respond { $0.chat == .null ? noContent : StubResponse(status: 204, body: Data(), delay: 0.8) }
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    attention.update(client: client, active: true, route: bot)
    attention.mount(bot)
    try await eventually { server.presence.count == 1 }
    // The heartbeat comes due while the first report is still in flight.
    try await pause(350)
    attention.update(client: client, active: false, route: bot)
    try await eventually { server.presence.count == 2 }
    #expect(server.presence[1].chat == .null)
    try await pause(600)
    #expect(server.presence.count == 2)

    server.respond { _ in noContent }
    attention.update(client: client, active: true, route: bot)
    try await eventually { server.presence.count == 3 }
    try await eventually { server.presence.count == 4 }
    #expect(server.presence.dropFirst(2).allSatisfy { $0.chatID == "a1" })
  })
}

@MainActor @Test func aNewAccountGetsANewViewAndTheOldOneClearsThroughTheOldSession() async throws {
  let server = AttentionServer()
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    attention.update(client: client, active: true, route: bot)
    attention.mount(bot)
    try await eventually { server.presence.count == 1 }
    let first = attention.viewID

    attention.update(client: other(client, token: "next"), active: true, route: bot)
    #expect(attention.viewID != first)
    try await eventually { server.presence.filter { $0.view == first }.count == 2 }
    let old = server.presence.filter { $0.view == first }
    #expect(old.map(\.chat) == [server.presence[0].chat, .null])
    #expect(old.allSatisfy { $0.token == "Bearer test-token" })
    let next = try #require(server.presence.last { $0.view == attention.viewID })
    #expect(next.token == "Bearer next")
    #expect(next.chatID == "a1")
  })
}

@MainActor @Test func seenRepliesGoInBatchesOf100AndRetryInTheirOwnChatAfterNavigation() async throws {
  let server = AttentionServer()
  let failures = Mutex(1)
  server.respond { request in
    guard request.method == "POST" else { return noContent }
    return failures.withLock { left in
      defer { left -= 1 }
      return left > 0 ? failure(503) : noContent
    }
  }
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    attention.update(client: client, active: true, route: bot)
    attention.mount(bot)
    let ids = (1...205).map { "e\($0)" }
    attention.show(ids + ids, in: bot)
    try await eventually { server.seen.count == 1 }
    #expect(server.seen[0].eventIDs.count == 100)

    attention.update(client: client, active: true, route: group)
    attention.mount(group)
    try await eventually { server.seen.count == 4 }
    #expect(server.seen.map(\.eventIDs.count) == [100, 100, 100, 5])
    #expect(server.seen.allSatisfy { $0.kind == "bot" && $0.chatID == "a1" })
    #expect(server.seen.dropFirst().flatMap(\.eventIDs) == ids)

    attention.update(client: client, active: true, route: bot)
    attention.mount(bot)
    attention.show(ids, in: bot, key: "again")
    try await pause()
    #expect(server.seen.count == 4)
  })
}

@MainActor @Test(arguments: [400, 404])
func aRefusedBatchIsSplitAndOnlyItsRefusedEventsAreDropped(status: Int) async throws {
  let server = AttentionServer()
  server.respond { $0.method == "POST" && $0.eventIDs.contains("bad") ? failure(status) : noContent }
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    attention.update(client: client, active: true, route: bot)
    attention.mount(bot)
    attention.show(["good", "bad", "also-good"], in: bot)
    try await eventually { server.seen.count == 4 }
    #expect(server.seen.map(\.eventIDs) == [["good", "bad", "also-good"], ["good"], ["bad"], ["also-good"]])
    try await pause()
    #expect(server.seen.count == 4)
  })
}

@MainActor @Test func anEndedSessionStopsSeenRetries() async throws {
  let server = AttentionServer()
  server.respond { $0.method == "POST" ? failure(401) : noContent }
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    attention.update(client: client, active: true, route: bot)
    attention.mount(bot)
    attention.show(["e1"], in: bot)
    try await eventually { server.seen.count == 1 }
    attention.show(["e2"], in: bot, key: "later")
    try await pause()
    #expect(server.seen.count == 1)
  })
}

@MainActor @Test func onlyAReadySurfaceInTheUncoveredViewportOfTheShownChatCounts() async throws {
  let server = AttentionServer()
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    let container = CGSize(width: 100, height: 100)
    let inside = CGRect(x: 0, y: 40, width: 50, height: 20)
    attention.update(client: client, active: true, route: bot)
    attention.setSurface("early", of: bot, frame: inside, container: container, eventIDs: ["early"], ready: true)
    try await pause(60)
    #expect(server.seen.isEmpty)

    attention.mount(bot)
    try await eventually { server.seen.count == 1 }
    #expect(server.seen[0].eventIDs == ["early"])

    attention.setViewportInsets(top: 0, bottom: 30)
    attention.setSurface("loading", of: bot, frame: inside, container: container, eventIDs: ["card"], ready: false)
    let below = CGRect(x: 0, y: 100, width: 50, height: 20)
    attention.setSurface("below", of: bot, frame: below, container: container, eventIDs: ["below"], ready: true)
    let covered = CGRect(x: 0, y: 75, width: 50, height: 20)
    attention.setSurface("covered", of: bot, frame: covered, container: container, eventIDs: ["covered"], ready: true)
    attention.setSurface("other", of: group, frame: inside, container: container, eventIDs: ["other"], ready: true)
    attention.update(client: client, active: false, route: bot)
    attention.setSurface("away", of: bot, frame: inside, container: container, eventIDs: ["away"], ready: true)
    try await pause()
    #expect(server.seen.count == 1)

    // Coming back to the app shows what is already on screen, though nothing moved.
    attention.update(client: client, active: true, route: bot)
    try await eventually { server.seen.count == 2 }
    #expect(server.seen[1].eventIDs == ["away"])
    attention.setSurface("loading", of: bot, frame: inside, container: container, eventIDs: ["card"], ready: true)
    try await eventually { server.seen.count == 3 }
    #expect(server.seen[2].eventIDs == ["card"])
  })
}

@MainActor @Test func signingOutClearsThroughTheOldSessionWithinTheTimeoutAndRefusesItAfterwards() async throws {
  let server = AttentionServer()
  server.respond { request in
    if request.method == "POST" { return failure(503) }
    return request.chat == .null ? StubResponse(status: 204, body: Data(), hold: true) : noContent
  }
  try await withClient(handler: server.handler, test: { client in
    let attention = ChatAttention(timing: timing)
    attention.update(client: client, active: true, route: bot)
    attention.mount(bot)
    attention.show(["e1"], in: bot)
    try await eventually { server.presence.count == 1 && !server.seen.isEmpty }
    let old = attention.viewID

    let started = ContinuousClock.now
    let closing = Task { await attention.disconnect(client) }
    await Task.yield()
    #expect(attention.viewID != old)
    attention.update(client: client, active: true, route: bot)
    attention.show(["late"], in: bot, key: "late")
    await closing.value
    let waited = ContinuousClock.now - started
    #expect(waited >= .milliseconds(250) && waited < .seconds(2))
    #expect(server.presence.count == 2)
    #expect(server.presence[1].view == old && server.presence[1].chat == .null)
    let seen = server.seen.count
    attention.update(client: nil, active: false, route: nil)
    attention.update(client: client, active: true, route: bot)
    try await pause()
    #expect(server.presence.count == 2)
    #expect(server.seen.count == seen)

    server.respond { _ in noContent }
    attention.update(client: other(client, token: "next"), active: true, route: bot)
    try await eventually { server.presence.last?.token == "Bearer next" }
    #expect(server.presence.last?.chatID == "a1")
  })
}
