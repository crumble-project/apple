import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import apfelkern

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(2)) }
  #expect(done())
}

private func bot(model: String, level: String = "off", tools: [String]? = nil) -> Agent {
  Agent(
    id: "a1", name: "Atlas", enabled: true, provider: "openai", model: model, tools: tools,
    inference: Inference(thinkingLevel: level, temperature: 0.5))
}

private let reasoningJSON = #"{"options":[{"value":"low","label":"Low"},{"value":"high","label":"Deep"}],"#
  + #""effectiveLevel":"low"}"#

@Test @MainActor func reasoningShowsWhatTheServerOffers() async throws {
  let asked = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    asked.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(reasoningJSON)
  }, test: { client in
    let board = ReasoningBoard()
    #expect(board.preview(of: bot(model: "o4")) == nil)

    await board.load(bot: bot(model: " o4 "), client: client, after: .zero)
    let preview = try #require(board.preview(of: bot(model: "o4")))
    #expect(preview.options.map(\.label) == ["Low", "Deep"])
    #expect(preview.effectiveLevel == .low)
    #expect(preview.label == "Low")
    #expect(asked.withLock { $0 } == [
      .object(["provider": .string("openai"), "model": .string("o4"), "thinkingLevel": .string("off")])
    ])
    // A level the server offered for the model shows as itself until its own preview arrives.
    #expect(board.preview(of: bot(model: "o4", level: "high"))?.effectiveLevel == .high)
    #expect(board.preview(of: bot(model: "o4", level: "medium")) == nil)
    #expect(board.preview(of: bot(model: "gpt")) == nil)

    board.reset()
    #expect(board.preview(of: bot(model: "o4")) == nil)
  })
}

@Test @MainActor func aReasoningPreviewForOldInputsOrAnOldConnectionIsDropped() async throws {
  let asked = Mutex(0)
  try await withClient(handler: { _ in
    asked.withLock { $0 += 1 }
    return json(reasoningJSON, delay: 0.05)
  }, test: { client in
    let board = ReasoningBoard()
    let changed = Task { await board.load(bot: bot(model: "o4"), client: client) }
    try await wait { asked.withLock { $0 } == 1 }
    changed.cancel()
    await changed.value
    #expect(board.preview(of: bot(model: "o4")) == nil)

    let reconnected = Task { await board.load(bot: bot(model: "o4"), client: client, after: .zero) }
    try await wait { asked.withLock { $0 } == 2 }
    board.reset()
    await reconnected.value
    #expect(board.preview(of: bot(model: "o4")) == nil)

    let typing = Task { await board.load(bot: bot(model: "o"), client: client, after: .milliseconds(50)) }
    typing.cancel()
    await typing.value
    #expect(asked.withLock { $0 } == 2)
  })
}

@Test @MainActor func aFailedReasoningPreviewHidesTheControl() async throws {
  try await withClient(handler: { _ in json(#"{"error":"down"}"#, status: 503) }, test: { client in
    let board = ReasoningBoard()
    await board.load(bot: bot(model: "o4"), client: client, after: .zero)
    #expect(board.preview(of: bot(model: "o4")) == nil)
  })
}

@Test @MainActor func aReasoningChoiceShowsAtOnceAndKeepsTheOtherSettings() async throws {
  let bodies = Mutex<[JSONValue]>([])
  let avatar = try #require(String(data: JSONEncoder().encode(bot(model: "o4").avatar), encoding: .utf8))
  let saved = #"{"id":"a1","name":"Atlas","avatar":\#(avatar),"description":"","instructions":"","#
    + #""provider":"openai","model":"o4","enabled":true,"tools":[],"skills":[],"mcpServers":[],"delegates":[],"#
    + #""inference":{"thinkingLevel":"high","temperature":0.5},"#
    + #""createdAt":"2026-11-05T10:00:00.000Z","updatedAt":"2026-11-05T10:00:00.000Z"}"#
  try await withClient(handler: { request in
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(saved, delay: 0.02)
  }, test: { client in
    let host = AvatarStubHost(bot(model: "o4", level: "low"), client: client)
    let board = ReasoningBoard()
    board.choose(.high, for: "a1", host: host)
    #expect(host.agents[0].inference?.thinkingLevel == "high")
    #expect(board.saving == ["a1"])

    board.choose(.medium, for: "a1", host: host)
    try await wait { board.saving.isEmpty }
    #expect(host.agents[0].inference?.thinkingLevel == "high")

    #expect(bodies.withLock { $0 } == [
      .object(["inference": .object(["thinkingLevel": .string("high"), "temperature": .number(0.5)])])
    ])
  })
}

@Test @MainActor func aRefusedReasoningChoiceRollsBack() async throws {
  try await withClient(handler: { _ in json(#"{"error":"Nope"}"#, status: 400, delay: 0.02) }, test: { client in
    let host = AvatarStubHost(bot(model: "o4", level: "low"), client: client)
    let board = ReasoningBoard()
    board.choose(.high, for: "a1", host: host)
    #expect(host.agents[0].inference?.thinkingLevel == "high")
    try await wait { board.saving.isEmpty }
    #expect(host.agents[0].inference?.thinkingLevel == "low")
    #expect(!host.errorText.isEmpty)
  })
}

@Test func mentionsReachEveryOtherEnabledBotOnceTheBotMayMessage() {
  let paused = Agent(id: "paused", name: "Paused", enabled: false)
  let other = Agent(id: "other", name: "Other", enabled: true)
  let source = bot(model: "o4", tools: ["delegate"])
  #expect(source.mentionableBots(in: [source, other, paused]).map(\.id) == ["other"])
  #expect(bot(model: "o4", tools: ["memory"]).mentionableBots(in: [other]).isEmpty)
}

@Test func theCreateBotsToggleFollowsTheTool() {
  var draft = AgentDraft(agent: bot(model: "o4", tools: ["create_bots", "future"]))
  #expect(draft.toolsCreateBots)
  #expect(draft.tools(keeping: ["create_bots", "future"]) == ["create_bots", "future"])
  draft.toolsCreateBots = false
  #expect(draft.tools(keeping: ["create_bots", "future"]) == ["future"])
  #expect(!AgentDraft(isNew: true, agentID: "").toolsCreateBots)
}

@Test func aPasteAttachesFilesAndImagesButLeavesTextAndLinks() {
  let attaches = PasteContent.attachesFiles
  #expect(attaches([UTType.png.identifier], false))
  #expect(attaches([UTType.png.identifier, UTType.utf8PlainText.identifier], true))
  #expect(attaches([UTType.fileURL.identifier, UTType.utf8PlainText.identifier], true))
  #expect(attaches([UTType.json.identifier], false))
  #expect(!attaches([UTType.utf8PlainText.identifier, UTType.rtf.identifier], true))
  #expect(!attaches([UTType.url.identifier, UTType.utf8PlainText.identifier], true))
  #expect(!attaches([UTType.url.identifier], false))
  #expect(PasteContent.fileType(in: [UTType.utf8PlainText.identifier, UTType.json.identifier]) == nil)
}

@Test func aMemoryNamesWhereItCameFrom() {
  #expect(memorySourceLabel(nil) == nil)
  #expect(memorySourceLabel(MemorySource(kind: "chat")) == "From the bot chat")
  #expect(memorySourceLabel(MemorySource(kind: "task", name: "Morning")) == "From the automation Morning")
}
