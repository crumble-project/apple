import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let typed = "made-up-secret"
private let botID = "11111111-1111-4111-8111-111111111111"

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

private func managers(connected: Bool, usedBy: String = "") -> StubResponse {
  json(#"{"passwordManagers":[\#(manager(connected: connected, usedBy: usedBy))]}"#)
}

private func manager(connected: Bool, usedBy: String = "") -> String {
  #"{"id":"1password","name":"1Password","connected":\#(connected),"connectedAt":null,"usedBy":[\#(usedBy)]}"#
}

private func secret(_ configured: Bool) -> String {
  #"{"configured":\#(configured),"passwordManager":null,"reference":null}"#
}

private func setting(_ configured: Bool) -> String {
  #"{"key":"token","kind":"secret","label":"Doorstep account token","whenMissing":"Needed","#
    + #""secret":\#(secret(configured))}"#
}

private func settings(_ configured: Bool) -> StubResponse {
  json(#"{"plugins":[{"id":"doorstep","contributes":[],"settings":[\#(setting(configured))]}]}"#)
}

private func gateway(enabled: Bool = false, owner: String = "null") -> String {
  #"{"id":"discord","label":"Discord","secretKey":"discord:token","tokenConfigured":false,"#
    + #""config":{"enabled":\#(enabled),"defaultBotId":null,"ownerId":\#(owner),"allowedChannelIds":[],"#
    + #""allowDirectMessages":false,"aliases":[]},"status":"disconnected","error":null,"#
    + #""failedCount":0,"pendingCount":0}"#
}

private func relay(url: String = "null", status: String = "disconnected") -> String {
  #"{"url":\#(url),"tokenConfigured":false,"status":"\#(status)","error":null}"#
}

private func path(_ request: URLRequest) -> String { request.url?.path ?? "" }

private func isGet(_ request: URLRequest) -> Bool { request.httpMethod == "GET" }

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

private let savedGateway = MessageGateway(
  id: "discord", label: "Discord", secretKey: "discord:token", tokenConfigured: true,
  config: GatewayConfig(), status: .disconnected)

@Test func secretDraftsKeepValuesOutOfDescriptionsAndDumps() {
  var token = PasswordManagerDraft(manager: PasswordManager(id: .onePassword, name: "1Password", connected: false))
  token.token = "  \(typed)\n"
  var value = PluginSettingDraft(setting: PluginSetting(
    pluginID: "doorstep", key: "token", label: "Token", secret: SecretStatus(configured: false)))
  value.source.value = typed
  for draft in [token as Any, value as Any] {
    var dumped = ""
    dump(draft, to: &dumped)
    #expect(!dumped.contains(typed))
    #expect(!String(describing: draft).contains(typed))
  }
  #expect(token.trimmedToken == typed)
  token.clearSecrets()
  value.clearSecrets()
  #expect(token.token.isEmpty)
  #expect(value.source.value.isEmpty)
}

@Test func aGatewayDraftTrimsAndDropsBlankAndRepeatedChannels() {
  var draft = GatewayDraft(gateway: savedGateway)
  #expect(!draft.isDirty)
  draft.ownerID = "  owner  "
  for value in ["general", " general ", "", "ops"] {
    var row = GatewayDraft.ChannelRow()
    row.value = value
    draft.channels.append(row)
  }
  #expect(draft.config.ownerID == "owner")
  #expect(draft.config.allowedChannelIDs == ["general", "ops"])
  #expect(draft.isDirty)
  draft.ownerID = "   "
  #expect(draft.config.ownerID == nil)
}

@Test func aGatewayDraftAppliesTheServersRules() {
  let bots = [Agent(id: botID, name: "Atlas")]
  var draft = GatewayDraft(gateway: savedGateway)
  draft.ownerID = "two words"
  #expect(draft.errors(bots: bots).owner != nil)
  draft.ownerID = "1234"
  #expect(draft.errors(bots: bots).isEmpty)

  var alias = GatewayDraft.AliasRow()
  alias.handle = "@research"
  alias.botID = botID
  draft.aliases = [alias]
  #expect(draft.errors(bots: bots).aliases?.contains("without @") == true)
  draft.aliases[0].handle = "research"
  draft.aliases[0].botID = ""
  #expect(draft.errors(bots: bots).aliases == "Choose a bot for every alias.")
  draft.aliases[0].botID = botID
  var repeated = GatewayDraft.AliasRow()
  repeated.handle = "RESEARCH"
  repeated.botID = botID
  draft.aliases.append(repeated)
  #expect(draft.errors(bots: bots).aliases?.contains("unique") == true)
}

@Test func deletedBotsOnlyBlockAGatewayThatIsOn() {
  var draft = GatewayDraft(gateway: savedGateway)
  draft.defaultBotID = botID
  #expect(draft.errors(bots: []).isEmpty)
  draft.enabled = true
  #expect(draft.errors(bots: []).defaultBot != nil)
  let choices = MessageGateway.botChoices([Agent(id: "a", name: "Pixel", enabled: false)], keeping: botID)
  #expect(choices.map(\.name) == ["Pixel (disabled)", "Deleted bot"])
}

@Test func nothingShowsAsAnErrorUntilSaveIsPressed() {
  var draft = GatewayDraft(gateway: savedGateway)
  draft.ownerID = "two words"
  #expect(draft.shownErrors(bots: []) == GatewayDraftErrors())
  draft.attempted = true
  #expect(draft.shownErrors(bots: []).owner != nil)
}

@MainActor @Test func aTokenWaitsForThePasswordManagerAndAFailureKeepsTheSheet() async throws {
  let refuse = Mutex(true)
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isGet(request) { return managers(connected: !refuse.withLock { $0 }) }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return refuse.withLock { $0 }
      ? json(#"{"error":"1Password rejected this token"}"#, status: 400, delay: 0.05)
      : json(manager(connected: true), delay: 0.05)
  }, test: { client in
    let board = PasswordManagerBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.open(board.managers[0])
    board.draft?.token = "  \(typed) "
    board.saveDraft(client: client)
    #expect(board.isSaving)
    board.closeDraft()
    #expect(board.draft != nil)
    #expect(!board.managers[0].connected)
    try await wait { !board.isSaving }
    #expect(board.saveError.contains("rejected"))
    #expect(board.draft?.token == "  \(typed) ")

    refuse.withLock { $0 = false }
    board.saveDraft(client: client)
    try await wait { board.draft == nil }
    #expect(board.managers[0].connected)
    #expect(board.saveError.isEmpty)
    #expect(bodies.withLock { $0.last } == .object(["token": .string(typed)]))
    board.reset()
  })
}

@MainActor @Test func aRefusedDisconnectComesBackAndAManagerInUseStaysConnected() async throws {
  try await withClient(handler: { request in
    if isGet(request) { return managers(connected: true) }
    return json(#"{"error":"Still in use"}"#, status: 409, delay: 0.05)
  }, test: { client in
    let board = PasswordManagerBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let manager = board.managers[0]
    board.disconnect(manager, client: client)
    #expect(!board.managers[0].connected)
    #expect(board.isUnconfirmed(manager))
    try await wait { board.errors[.onePassword] != nil }
    #expect(board.managers[0].connected)
    #expect(!board.isUnconfirmed(manager))

    var inUse = manager
    inUse.usedBy = ["mcp:one"]
    board.disconnect(inUse, client: client)
    #expect(!board.isUnconfirmed(inUse))
    try await Task.sleep(for: .milliseconds(100))
    board.reset()
  })
}

@MainActor @Test func aFailedValueComesBackWithWhatTheOwnerTyped() async throws {
  let bodies = Mutex<[JSONValue]>([])
  let writes = Mutex(0)
  try await withClient(handler: { request in
    if path(request).hasSuffix("/plugin-settings") { return settings(writes.withLock { $0 } > 1) }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    let write = writes.withLock {
      $0 += 1
      return $0
    }
    return write == 1
      ? json(#"{"error":"Could not save"}"#, status: 500, delay: 0.05)
      : json(setting(true), delay: 0.05)
  }, test: { client in
    let board = PluginSettingBoard()
    var notified = 0
    board.onChange = { _ in notified += 1 }
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let row = board.settings(.eventRelay)[0]
    board.edit(row)
    board.draft?.source.value = typed
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(board.settings(.eventRelay)[0].secret.configured)
    #expect(board.isUnconfirmed(row))
    try await wait { board.draft != nil }
    #expect(board.saveError.contains("Could not save"))
    #expect(board.draft?.source.value == typed)
    try await wait { !board.settings(.eventRelay)[0].secret.configured }

    board.saveDraft(client: client)
    try await wait { !board.isUnconfirmed(row) }
    #expect(board.settings(.eventRelay)[0].secret.configured)
    #expect(bodies.withLock { $0.last } == .object(["value": .string(typed)]))
    #expect(notified == 2)
    board.reset()
  })
}

@MainActor @Test func aReferenceHoldsTheSheetUntilThePasswordManagerAnswers() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isGet(request) { return settings(bodies.withLock { !$0.isEmpty }) }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(setting(true), delay: 0.05)
  }, test: { client in
    let board = PluginSettingBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.edit(board.settings(.eventRelay)[0])
    board.draft?.source.use(.onePassword)
    board.draft?.source.reference = "op://vault/item/token"
    board.saveDraft(client: client)
    #expect(board.isSaving)
    #expect(board.draft != nil)
    #expect(!board.settings(.eventRelay)[0].secret.configured)
    try await wait { board.draft == nil }
    #expect(board.settings(.eventRelay)[0].secret.configured)
    let reference: JSONValue = .object([
      "passwordManager": .string("1password"), "reference": .string("op://vault/item/token")
    ])
    #expect(bodies.withLock { $0.last } == .object(["reference": reference]))
    board.reset()
  })
}

@MainActor @Test func removingASettingAppliesAtOnceAndAFailureBringsItBack() async throws {
  try await withClient(handler: { request in
    if isGet(request) { return settings(true) }
    return json(#"{"error":"Could not remove"}"#, status: 500, delay: 0.05)
  }, test: { client in
    let board = PluginSettingBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let row = board.settings(.eventRelay)[0]
    board.remove(row, client: client)
    #expect(!board.settings(.eventRelay)[0].secret.configured)
    try await wait { board.errors[row.id] != nil }
    #expect(board.settings(.eventRelay)[0].secret.configured)
    board.reset()
  })
}

@MainActor @Test func aGatewaySaveAppliesAtOnceAndSendsItsEmptyFieldsAsNull() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isGet(request) {
      let saved = bodies.withLock { !$0.isEmpty }
      return json(#"{"gateways":[\#(gateway(enabled: saved))]}"#)
    }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(gateway(enabled: true), delay: 0.05)
  }, test: { client in
    let board = MessageGatewayBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    let row = board.gateways[0]
    #expect(row.statusLabel == "Disabled")
    board.edit(row)
    board.draft?.enabled = true
    board.saveDraft(bots: [], client: client)
    #expect(board.draft == nil)
    #expect(board.gateways[0].config.enabled)
    #expect(board.isUnconfirmed(row))
    try await wait { !board.isUnconfirmed(row) }
    #expect(board.gateways[0].statusLabel == "Disconnected")
    guard case .object(let body)? = bodies.withLock({ $0.last }) else {
      Issue.record("No body")
      return
    }
    #expect(body["defaultBotId"] == .null)
    #expect(body["ownerId"] == .null)
    #expect(body["enabled"] == .bool(true))
    board.reset()
  })
}

@MainActor @Test func aFailedGatewaySaveGivesTheSheetBackAndAnInvalidOneStaysOpen() async throws {
  try await withClient(handler: { request in
    if isGet(request) { return json(#"{"gateways":[\#(gateway())]}"#) }
    return json(#"{"error":"Unknown bot"}"#, status: 400, delay: 0.05)
  }, test: { client in
    let board = MessageGatewayBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.edit(board.gateways[0])
    board.draft?.ownerID = "two words"
    board.saveDraft(bots: [], client: client)
    #expect(board.draft?.shownErrors(bots: []).owner != nil)
    #expect(!board.isUnconfirmed(board.gateways[0]))

    board.draft?.ownerID = "1234"
    board.saveDraft(bots: [], client: client)
    #expect(board.draft == nil)
    try await wait { board.draft != nil }
    #expect(board.saveError.contains("Unknown bot"))
    #expect(board.draft?.ownerID == "1234")
    #expect(board.gateways[0].config.ownerID == nil)
    board.reset()
  })
}

@MainActor @Test func aLateGatewayAnswerDoesNotReachANewConnection() async throws {
  try await withClient(handler: { request in
    if isGet(request) { return json(#"{"gateways":[\#(gateway())]}"#, delay: 0.05) }
    return json(gateway())
  }, test: { client in
    let board = MessageGatewayBoard()
    board.refresh(client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(150))
    #expect(!board.isLoaded)
    #expect(board.gateways.isEmpty)
  })
}

@MainActor @Test func aRelaySaveShowsPendingAndKeepsAURLTypedSince() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isGet(request) { return json(relay()) }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(relay(url: #""https://relay.example.com""#, status: "connecting"), delay: 0.05)
  }, test: { client in
    let board = EventRelayBoard()
    #expect(board.watchKey == nil)
    board.refresh(client: client)
    try await wait { board.relay != nil }
    #expect(!board.canSave)
    board.url = " https://relay.example.com "
    #expect(board.canSave)
    board.save(client: client)
    #expect(board.isSaving)
    #expect(!board.canSave)
    board.url = "https://other.example.com"
    try await wait { !board.isSaving }
    #expect(board.relay?.url == "https://relay.example.com")
    #expect(board.url == "https://other.example.com")
    #expect(board.watchKey != nil)
    #expect(bodies.withLock { $0.last } == .object(["url": .string("https://relay.example.com")]))
  })
}

@MainActor @Test func clearingTheRelaySendsNullAndAFailureKeepsTheField() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isGet(request) { return json(relay(url: #""https://relay.example.com""#)) }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return json(#"{"error":"Could not disconnect"}"#, status: 500)
  }, test: { client in
    let board = EventRelayBoard()
    board.refresh(client: client)
    try await wait { board.relay != nil }
    #expect(board.url == "https://relay.example.com")
    board.url = ""
    board.save(client: client)
    try await wait { !board.isSaving }
    #expect(board.saveError?.contains("Could not disconnect") == true)
    #expect(board.url.isEmpty)
    #expect(bodies.withLock { $0.last } == .object(["url": .null]))
  })
}

@MainActor @Test func theRelayFieldFollowsReadsUntilTheOwnerTypes() async throws {
  let url = Mutex("null")
  try await withClient(handler: { _ in json(relay(url: url.withLock { $0 })) }, test: { client in
    let board = EventRelayBoard()
    board.refresh(client: client)
    try await wait { board.relay != nil }
    url.withLock { $0 = #""https://a.example.com""# }
    board.refresh(client: client)
    try await wait { board.url == "https://a.example.com" }
    board.url = "https://typed.example.com"
    url.withLock { $0 = #""https://b.example.com""# }
    board.refresh(client: client)
    try await wait { board.relay?.url == "https://b.example.com" }
    #expect(board.url == "https://typed.example.com")
  })
}

@MainActor @Test func aSettingChangeRereadsWhatDependsOnIt() async throws {
  let reads = Mutex<Set<String>>([])
  try await withClient(handler: { request in
    if isGet(request) {
      reads.withLock { _ = $0.insert(path(request)) }
      if path(request).hasSuffix("/plugin-settings") { return settings(true) }
      if path(request).hasSuffix("/message-gateways") { return json(#"{"gateways":[\#(gateway())]}"#) }
      if path(request).hasSuffix("/event-relay") { return json(relay()) }
      if path(request).hasSuffix("/event-sources") { return json(#"{"sources":[]}"#) }
      return managers(connected: false)
    }
    return json(setting(false))
  }, test: { client in
    let services = ConnectedServices()
    services.refresh(.webSearch, client: client)
    try await wait { services.pluginSettings.isLoaded }
    services.pluginSettings.remove(services.pluginSettings.settings(.eventRelay)[0], client: client)
    try await wait {
      services.relay.relay != nil && services.gateways.isLoaded && services.eventSources.isLoaded
    }
    #expect(reads.withLock { $0.count } == 6)
    services.reset()
    try await Task.sleep(for: .milliseconds(100))
  })
}
