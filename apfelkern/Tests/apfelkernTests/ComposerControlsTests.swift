import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import apfelkern

private let modelsJSON = """
  [{"provider":"openai","id":"o4","name":"o4","contextWindow":1000,"reasoning":true,
    "thinkingLevels":["low","medium","high"]},
   {"provider":"openai","id":"gpt","name":"gpt","contextWindow":1000,"reasoning":false,
    "thinkingLevels":["off"]}]
  """

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

@Test(arguments: [
  (ThinkingLevel.medium, [ThinkingLevel.low, .medium], ThinkingLevel.medium),
  (.off, [.low, .high], .low),
  (.medium, [.low, .high], .high),
  (.max, [.low, .high], .high),
  (.high, [], .off)
])
func aLevelClampsToTheNearestPreferringHigher(level: ThinkingLevel, levels: [ThinkingLevel], result: ThinkingLevel) {
  #expect(level.clamped(to: levels) == result)
}

@Test @MainActor func reasoningFollowsTheModelsLevels() async throws {
  try await withClient(handler: { _ in json(modelsJSON) }, test: { client in
    let board = ReasoningBoard()
    #expect(board.levels(of: bot(model: "o4")).isEmpty)

    await board.load(provider: "openai", client: client)
    #expect(board.levels(of: bot(model: "o4")) == [.low, .medium, .high])
    #expect(board.level(of: bot(model: "o4", level: "off")) == .low)
    #expect(board.level(of: bot(model: "o4", level: "xhigh")) == .high)
    #expect(board.levels(of: bot(model: "gpt")) == [.off])
    #expect(board.levels(of: bot(model: "unlisted")) == ThinkingLevel.allCases)

    board.reset()
    #expect(board.levels(of: bot(model: "o4")).isEmpty)
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

@Test func anAutomationsCadenceReadsInWords() {
  let words = { (cron: String) in
    cadence(Schedule(id: "s", agentId: "a", name: "n", cron: cron, prompt: "p", timezone: TimeZone.current.identifier,
                     enabled: true))
  }
  #expect(words("*/5 * * * *") == "Every 5 minutes")
  #expect(words("30 * * * *") == "Every hour at :30")
  #expect(words("0 8 * * *").hasPrefix("Every day at "))
  #expect(words("not a cron") == "not a cron")
  #expect(cadence(Schedule(id: "s", agentId: "a", name: "n", prompt: "p", enabled: true)) == "Once")
}

@Test func aMemoryNamesWhereItCameFrom() {
  #expect(memorySourceLabel(nil) == nil)
  #expect(memorySourceLabel(MemorySource(kind: "chat")) == "From the bot chat")
  #expect(memorySourceLabel(MemorySource(kind: "task", name: "Morning")) == "From the automation Morning")
}
