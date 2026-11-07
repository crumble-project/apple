import Foundation
import Synchronization
import Testing

@testable import apfelkern

private let ownerJSON = #"{"holder":"owner","changes":1,"updatedAt":"now"}"#
private let botJSON = #"{"holder":"bot","changes":2,"updatedAt":"now"}"#
private let viewerPath = "/prefix/v1/agents/a1/desktop/viewer"

private func json(_ text: String, status: Int = 200) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8))
}

@MainActor private func eventually(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// A request cancelled just as it started still reaches the stub, which must outlive it.
private func settle() async {
  try? await Task.sleep(for: .milliseconds(50))
}

@Test func takingControlStaysPendingUntilTheServerConfirms() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "PUT" ? json(ownerJSON) : json("", status: 404)
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.take()

    #expect(session.pending == .owner)
    #expect(session.holder == .bot)
    await eventually { session.pending == nil }
    #expect(session.holder == .owner)
    #expect(session.action == .handBack)
    #expect(session.controlLabel == "You have control")
    #expect(session.error.isEmpty)
  })
}

@Test func aFailedTakeLeavesTheBotInControlAndSaysWhy() async throws {
  try await withClient(handler: { request in
    request.httpMethod == "PUT"
      ? json(#"{"error":"This bot has no bot desktop"}"#, status: 409) : json("", status: 404)
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.take()
    await eventually { session.pending == nil }

    #expect(session.holder == .bot)
    #expect(session.error.contains("no bot desktop"))
  })
}

@Test func aServerWithoutABotDesktopShowsWhyInsteadOfAViewer() async throws {
  try await withClient(handler: { request in
    request.url?.path == viewerPath
      ? json(#"{"error":"This bot has no bot desktop"}"#, status: 409) : json("", status: 404)
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.connect()
    await eventually { !session.connecting && !session.error.isEmpty }

    #expect(session.link == nil)
    #expect(session.error.contains("no bot desktop"))
    session.leave()
    await settle()
  })
}

@Test func controlChangedElsewhereShowsUp() async throws {
  try await withClient(handler: { request in
    switch request.url?.path {
    case "/prefix/v1/agents/a1/desktop/events":
      StubResponse(
        contentType: "text/event-stream", body: Data("event: control\ndata: \(ownerJSON)\n\n".utf8), open: true)
    case viewerPath: json(#"{"path":"/desktop-viewer/one","expiresAt":"soon"}"#, status: 201)
    default: json("", status: 404)
    }
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    #expect(session.action == .waiting)
    #expect(session.controlLabel == nil)

    session.connect()
    await eventually { session.holder == .owner && session.link != nil }

    #expect(session.holder == .owner)
    #expect(session.link?.path.hasSuffix("/desktop-viewer/one") == true)
    session.leave()
    await eventually { session.pending == nil }
    await settle()
  })
}

@Test func reconnectingAsksForANewSingleUseLink() async throws {
  let issued = Mutex(0)
  try await withClient(handler: { request in
    guard request.url?.path == viewerPath else { return json("", status: 404) }
    let number = issued.withLock {
      $0 += 1
      return $0
    }
    return json(#"{"path":"/desktop-viewer/t\#(number)","expiresAt":"soon"}"#, status: 201)
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.reconnect()
    await eventually { session.link != nil && !session.connecting }
    session.reconnect()
    await eventually { session.link?.path.hasSuffix("t2") == true }

    #expect(issued.withLock { $0 } == 2)
  })
}

@Test func handingBackIsOfferedOnlyToTheOwner() {
  #expect(BotDesktopSession.action(for: .bot, pending: nil) == .take)
  #expect(BotDesktopSession.action(for: .owner, pending: nil) == .handBack)
  #expect(BotDesktopSession.action(for: .bot, pending: .owner) == .waiting)
}

@Test func leavingHandsBackControlEvenIfTheTakeIsStillOnItsWay() async throws {
  let asked = Mutex<[String]>([])
  try await withClient(handler: { request in
    guard request.httpMethod == "PUT" else { return json("", status: 404) }
    let body = try requestJSON(request)
    asked.withLock { $0.append(body["holder"]?.stringValue ?? "") }
    return json(body["holder"]?.stringValue == "owner" ? ownerJSON : botJSON)
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.take()
    session.leave()
    await eventually { session.holder == .bot && session.changes == 2 }

    #expect(asked.withLock { $0 } == ["owner", "bot"])
  })
}

@Test func settlingWaitsForTheHandBackOfATakeStillOnItsWay() async throws {
  try await withClient(handler: { request in
    guard request.httpMethod == "PUT" else { return json("", status: 404) }
    return json(try requestJSON(request)["holder"]?.stringValue == "owner" ? ownerJSON : botJSON)
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.take()
    session.leave()
    await session.settle()

    #expect(session.holder == .bot)
    #expect(session.changes == 2)
    #expect(session.pending == nil)
  })
}

@Test func returningBeforeATakeIsConfirmedKeepsControl() async throws {
  try await withClient(handler: { request in
    switch (request.httpMethod, request.url?.path) {
    case ("PUT", _): return json(ownerJSON)
    case (_, "/prefix/v1/agents/a1/desktop/events"):
      return StubResponse(contentType: "text/event-stream", body: Data(), open: true)
    case (_, viewerPath): return json(#"{"path":"/desktop-viewer/one","expiresAt":"soon"}"#, status: 201)
    default: return json("", status: 404)
    }
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.take()
    session.leave()
    session.connect()
    await session.settle()

    #expect(session.holder == .owner)
    session.leave()
    await session.settle()
  })
}

@Test func aHandBackThatFailsAfterLeavingIsNotRetriedForever() async throws {
  let handBacks = Mutex(0)
  try await withClient(handler: { request in
    switch (request.httpMethod, request.url?.path) {
    case ("PUT", _):
      handBacks.withLock { $0 += 1 }
      return json("", status: 500)
    case (_, "/prefix/v1/agents/a1/desktop/events"):
      return StubResponse(
        contentType: "text/event-stream", body: Data("event: control\ndata: \(ownerJSON)\n\n".utf8), open: true)
    case (_, viewerPath): return json(#"{"path":"/desktop-viewer/one","expiresAt":"soon"}"#, status: 201)
    default: return json("", status: 404)
    }
  }, test: { @MainActor client in
    let session = BotDesktopSession(agentID: "a1", client: client)
    session.connect()
    await eventually { session.holder == .owner }
    session.leave()
    await eventually { handBacks.withLock { $0 } > 0 && session.pending == nil }
    // session.settle() would never return under the retry loop this test guards against.
    await settle()

    #expect(handBacks.withLock { $0 } == 1)
    #expect(session.pending == nil)
  })
}

@Test func aRunningDesktopPreviewsWithAPassiveLink() async throws {
  let queries = Mutex<[String?]>([])
  try await withClient(handler: { request in
    switch request.url?.path {
    case "/prefix/v1/agents/a1/desktop/status": return json(#"{"running":true}"#)
    case viewerPath:
      queries.withLock { $0.append(request.url?.query) }
      return json(#"{"path":"/desktop-viewer/p","expiresAt":"soon"}"#, status: 201)
    default: return json("", status: 404)
    }
  }, test: { @MainActor client in
    let preview = BotDesktopPreview(agentID: "a1", client: client)
    preview.start()
    await eventually { preview.link != nil }
    preview.stop()
    await settle()

    #expect(queries.withLock { $0 } == ["passive=true"])
    #expect(preview.link == nil)
  })
}

@Test func aSleepingDesktopAsksForNoViewerUntilWoken() async throws {
  let queries = Mutex<[String?]>([])
  try await withClient(handler: { request in
    switch request.url?.path {
    case "/prefix/v1/agents/a1/desktop/status": return json(#"{"running":false}"#)
    case viewerPath:
      queries.withLock { $0.append(request.url?.query) }
      return json(#"{"path":"/desktop-viewer/p","expiresAt":"soon"}"#, status: 201)
    default: return json("", status: 404)
    }
  }, test: { @MainActor client in
    let preview = BotDesktopPreview(agentID: "a1", client: client, pollInterval: .milliseconds(10))
    preview.start()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!preview.live)
    #expect(queries.withLock { $0 }.isEmpty)

    preview.wake()
    #expect(preview.live)
    await eventually { preview.link != nil }
    preview.stop()
    await settle()

    #expect(queries.withLock { $0 } == [nil])
  })
}

@Test func aDesktopThatStopsGoesBackToSleep() async throws {
  let running = Mutex(true)
  try await withClient(handler: { request in
    switch request.url?.path {
    case "/prefix/v1/agents/a1/desktop/status":
      return json(running.withLock { $0 } ? #"{"running":true}"# : #"{"running":false}"#)
    case viewerPath: return json(#"{"path":"/desktop-viewer/p","expiresAt":"soon"}"#, status: 201)
    default: return json("", status: 404)
    }
  }, test: { @MainActor client in
    let preview = BotDesktopPreview(agentID: "a1", client: client, pollInterval: .milliseconds(10))
    preview.start()
    await eventually { preview.link != nil }
    running.withLock { $0 = false }
    await eventually { !preview.live }
    preview.stop()
    await settle()

    #expect(!preview.live)
    #expect(preview.link == nil)
  })
}

@Test func savingKeepsToolsTheEditorHasNoToggleFor() {
  var draft = AgentDraft(isNew: false, agentID: "a1", toolsDelegate: false, toolsCodemode: false, toolsDesktop: true)
  #expect(draft.tools(keeping: ["desktop", "future"]) == ["memory", "web", "schedule", "desktop", "future"])
  draft.toolsDesktop = false
  #expect(draft.tools(keeping: ["desktop", "future"]) == ["memory", "web", "schedule", "future"])
}

@Test func aDesktopModelNeedsBothProviderAndModel() {
  var draft = AgentDraft(isNew: false, agentID: "a1", desktopProvider: " opencode-go ", desktopModel: "")
  #expect(draft.desktopModelChoice == nil)
  draft.desktopModel = "gpt-6-luna"
  #expect(draft.desktopModelChoice == DesktopModel(provider: "opencode-go", model: "gpt-6-luna"))
}
