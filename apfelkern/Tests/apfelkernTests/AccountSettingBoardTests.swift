import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

private func webSearch(_ provider: String, exaKey: Bool = false) -> String {
  #"{"defaultProvider":"\#(provider)","exaKeyConfigured":\#(exaKey)}"#
}

private func vision(_ model: String) -> String {
  let chosen = model == "null" ? "null" : #"{"provider":"openai","model":"\#(model)"}"#
  return #"{"visionModel":\#(chosen),"choices":[{"provider":"openai","model":"gpt-eye","name":"GPT Eye"}]}"#
}

private let classifier = #"{"provider":"openai","model":"gpt-judge","name":"GPT Judge","kind":"classifier"}"#
private let judge = #"{"judgeModel":null,"effective":\#(classifier),"choices":[\#(classifier)]}"#

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

private func isGet(_ request: URLRequest) -> Bool { request.httpMethod == "GET" }

@MainActor @Test func aChoiceShowsAtOnceAndARefreshCannotTakeItAway() async throws {
  try await withClient(handler: { request in
    isGet(request) ? json(webSearch("mixed")) : json(webSearch("exa"), delay: 0.1)
  }, test: { client in
    let board = ConnectedServices().webSearch
    board.refresh(client: client)
    try await wait { board.setting != nil }
    board.choose(.exa, client: client)
    #expect(board.setting?.defaultProvider == .exa)
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(30))
    #expect(board.setting?.defaultProvider == .exa)
    #expect(board.setting?.warning == "Exa needs a key before bots can search with it.")
    board.reset()
  })
}

@MainActor @Test func aFailedChoiceComesBackWithItsError() async throws {
  try await withClient(handler: { request in
    isGet(request) ? json(webSearch("mixed")) : json(#"{"error":"nope"}"#, status: 409)
  }, test: { client in
    let board = ConnectedServices().webSearch
    board.refresh(client: client)
    try await wait { board.setting != nil }
    board.choose(.exa, client: client)
    try await wait { board.saveError != nil }
    #expect(board.saveError == "nope")
    #expect(board.setting?.defaultProvider == .mixed)
    board.reset()
  })
}

@MainActor @Test func choicesMadeDuringAWriteEndOnTheLastOne() async throws {
  let sent = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isGet(request) { return json(vision("null")) }
    let body = try requestJSON(request)
    sent.withLock { $0.append(body) }
    let model = body["visionModel"]?["model"]?.stringValue ?? "null"
    return json(vision(model), delay: 0.03)
  }, test: { client in
    let board = ConnectedServices().visionModel
    board.refresh(client: client)
    try await wait { board.setting != nil }
    let first = ModelRef(provider: "openai", model: "gpt-eye")
    board.choose(first, client: client)
    board.choose(ModelRef(provider: "openai", model: "gpt-skipped"), client: client)
    board.choose(nil, client: client)
    #expect(board.setting?.visionModel == nil)
    try await wait { sent.withLock { $0.count } == 2 }
    try await Task.sleep(for: .milliseconds(60))
    #expect(sent.withLock { $0.map { $0["visionModel"] == .null } } == [false, true])
    #expect(board.setting?.visionModel == nil)
    board.reset()
  })
}

@MainActor @Test func aRefusedChoiceReplacedDuringItsWriteShowsNoError() async throws {
  let sent = Mutex(0)
  try await withClient(handler: { request in
    if isGet(request) { return json(vision("null")) }
    sent.withLock { $0 += 1 }
    let model = try requestJSON(request)["visionModel"]?["model"]?.stringValue ?? "null"
    return model == "gpt-refused"
      ? json(#"{"error":"nope"}"#, status: 400, delay: 0.03) : json(vision(model), delay: 0.03)
  }, test: { client in
    let board = ConnectedServices().visionModel
    board.refresh(client: client)
    try await wait { board.setting != nil }
    board.choose(ModelRef(provider: "openai", model: "gpt-refused"), client: client)
    board.choose(ModelRef(provider: "openai", model: "gpt-eye"), client: client)
    try await wait { sent.withLock { $0 } == 2 }
    #expect(board.saveError == nil)
    try await Task.sleep(for: .milliseconds(60))
    #expect(board.setting?.visionModel?.model == "gpt-eye")
    #expect(board.saveError == nil)
    board.reset()
  })
}

@MainActor @Test func resetDropsAChoiceFromTheOldConnection() async throws {
  try await withClient(handler: { request in
    isGet(request) ? json(webSearch("mixed")) : json(webSearch("exa"), delay: 0.03)
  }, test: { client in
    let board = ConnectedServices().webSearch
    board.refresh(client: client)
    try await wait { board.setting != nil }
    board.choose(.exa, client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(60))
    #expect(board.setting == nil)
  })
}

@MainActor @Test func aJudgeModelGoesBackToTheDefaultWithNull() async throws {
  let sent = Mutex<JSONValue?>(nil)
  try await withClient(handler: { request in
    if isGet(request) {
      return json(#"{"judgeModel":{"provider":"openai","model":"gpt-judge"},"effective":\#(classifier),"#
        + #""choices":[\#(classifier)]}"#)
    }
    sent.withLock { $0 = try? requestJSON(request) }
    return json(judge)
  }, test: { client in
    let board = ConnectedServices().judgeModel
    board.refresh(client: client)
    try await wait { board.setting != nil }
    #expect(board.setting?.status == "GPT Judge judges now.")
    board.choose(nil, client: client)
    try await wait { sent.withLock { $0 != nil } }
    #expect(sent.withLock { $0 }?["judgeModel"] == .null)
    board.reset()
  })
}

@Test func aChosenModelNoKeyReachesStaysListed() {
  let gone = ModelRef(provider: "openai", model: "gpt-gone")
  let setting = VisionModelSettings(
    visionModel: gone,
    choices: [ModelChoice(ref: ModelRef(provider: "openai", model: "gpt-eye"), name: "GPT Eye")])
  #expect(setting.options.map(\.label) == ["Off", "GPT Eye", "gpt-gone (no key)"])
  #expect(setting.status == "No provider key reaches gpt-gone, so images can't be read. "
    + "Choose another model or turn it off.")
}

@Test func theJudgeSaysWhenOnlyAChatModelOrNothingJudges() {
  let chat = JudgeChoice(
    choice: ModelChoice(ref: ModelRef(provider: "openai", model: "gpt-small"), name: "GPT Small"), kind: .chat)
  #expect(JudgeModelSettings(judgeModel: nil, effective: chat, choices: []).status
    == "GPT Small judges as a chat model: no provider key reaches a classifier.")
  #expect(JudgeModelSettings(judgeModel: nil, effective: nil, choices: []).status.hasPrefix("No model is available"))
}

@Test func aBotKeepsItsWebSearchProviderThroughTheEditor() throws {
  var draft = AgentDraft(agent: Agent(name: "A", tools: ["web"], webSearchProvider: .exa))
  #expect(draft.toolsWeb)
  #expect(draft.webSearchProvider == .exa)
  draft.toolsWeb = false
  #expect(draft.tools(keeping: ["web"]).contains("web") == false)
  #expect(AgentDraft(agent: Agent(name: "B", tools: [])).toolsWeb == false)
  #expect(AgentDraft(isNew: true, agentID: "").toolsWeb)
}
