import Foundation
import Testing
@testable import apfelkern

private func reply(
  _ agent: String = "a1", group: String? = nil, origin: String = "chat"
) -> ActivityEvent {
  ActivityEvent(type: "reply", agentId: agent, agentName: "Atlas", origin: origin, groupId: group)
}

@Test func unreadCountsRepliesByChatAndSeeingAChatClearsOnlyThatChat() {
  var unread = UnreadCounts()
  #expect(unread.badgeLabel == nil)
  unread.add(reply())
  unread.add(reply())
  unread.add(reply("a2", group: "g1"))
  #expect(unread.total == 3)
  #expect(unread.badgeLabel == "3")
  unread.markSeen(.group("g1"))
  #expect(unread.total == 2)
  unread.markSeen(.memory)
  unread.markSeen(nil)
  #expect(unread.total == 2)
  unread.markSeen(.agent("a1"))
  #expect(unread.total == 0)
  #expect(unread.badgeLabel == nil)
}

@Test func unreadIgnoresBotToBotRepliesAndPreviews() {
  var unread = UnreadCounts()
  unread.add(reply(origin: "bot"))
  unread.add(ActivityEvent(type: "chat-preview", agentId: "a1", agentName: "Atlas", lastMessage: "Hi"))
  #expect(unread.total == 0)
}

@Test func memoryLineJoinsSourceAndAge() throws {
  let now = try #require(automationRunDate("2026-11-05T12:00:00.000Z"))
  var memory = Memory(
    id: "m", content: "x", updatedAt: "2026-11-05T10:00:00.000Z", source: MemorySource(kind: "owner"))
  #expect(memoryLine(memory, now: now) == "Added by you · " + ageLabel(now.addingTimeInterval(-7200), now: now))
  memory.source = nil
  #expect(memoryLine(memory, now: now)?.contains("·") == false)
  memory.updatedAt = nil
  #expect(memoryLine(memory, now: now) == nil)
}

@Test func ageUsesTheLargestUnitThatFits() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let locale = Locale.current.language.languageCode?.identifier
  guard locale == "en" else { return }
  #expect(ageLabel(now.addingTimeInterval(-30), now: now) == "this minute")
  #expect(ageLabel(now.addingTimeInterval(-300), now: now) == "5 minutes ago")
  #expect(ageLabel(now.addingTimeInterval(-7200), now: now) == "2 hours ago")
  #expect(ageLabel(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
  #expect(ageLabel(now.addingTimeInterval(-14 * 86_400), now: now) == "2 weeks ago")
  #expect(ageLabel(now.addingTimeInterval(-90 * 86_400), now: now) == "3 months ago")
  #expect(ageLabel(now.addingTimeInterval(-800 * 86_400), now: now) == "2 years ago")
}

@Test func searchMatchesFindEveryCaseInsensitiveOccurrence() {
  let text = "Ships on Thursdays, ships fast"
  #expect(searchMatches(of: " SHIPS ", in: text).map { String(text[$0]) } == ["Ships", "ships"])
  #expect(searchMatches(of: "  ", in: text).isEmpty)
  #expect(searchMatches(of: "aa", in: "aaa").count == 1)
}

@Test func mcpServersMatchByNameOrAddress() {
  let server = MCPServer(id: "s", name: "GitHub", url: "https://api.example.com/mcp", enabled: true)
  #expect(server.matches(""))
  #expect(server.matches(" github "))
  #expect(server.matches("EXAMPLE"))
  #expect(!server.matches("linear"))
}

@Test func aNewServerSendsItsOAuthAppAndOmitsAnEmptyOne() {
  var draft = MCPDraft(serverID: "")
  #expect(draft.payload(name: "n", url: "u")["oauthClientId"] == nil)
  draft.clientSecret.value = "ignored-without-a-client"
  #expect(draft.payload(name: "n", url: "u")["oauthClientSecret"] == nil)
  draft.clientID = " client-1 "
  let payload = draft.payload(name: "n", url: "u")
  #expect(payload["oauthClientId"] == .string("client-1"))
  #expect(payload["oauthClientSecret"] == .object(["value": .string("ignored-without-a-client")]))
}

@Test func anUntouchedSecretStaysOutOfASave() {
  let server = MCPServer(
    id: "s", name: "n", url: "u", enabled: true, auth: "oauth", oauthClientId: "client-1",
    oauthClientSecret: SecretStatus(configured: true))
  let draft = MCPDraft(server: server)
  #expect(draft.clientID == "client-1")
  #expect(draft.clientSecret.value.isEmpty)
  #expect(draft.clientSecretPlaceholder == "Replace the saved secret")
  let payload = draft.payload(name: "n", url: "u")
  #expect(payload["oauthClientId"] == .string("client-1"))
  #expect(payload["oauthClientSecret"] == nil)
  #expect(!draft.changesOAuthApp)
  #expect(draft.applyingOAuthApp(to: server).auth == "oauth")
}

@Test func clearingTheClientIDClearsTheSecretAndSignsOut() {
  let server = MCPServer(
    id: "s", name: "n", url: "u", enabled: true, auth: "oauth", oauthClientId: "client-1",
    oauthClientSecret: SecretStatus(configured: true))
  var draft = MCPDraft(server: server)
  draft.clientID = ""
  let payload = draft.payload(name: "n", url: "u")
  #expect(payload["oauthClientId"] == .null)
  #expect(payload["oauthClientSecret"] == .null)
  let shown = draft.applyingOAuthApp(to: server)
  #expect(shown.oauthClientId == nil)
  #expect(shown.oauthClientSecret.configured == false)
  #expect(shown.auth == "none")
}

@Test func aReferencedClientSecretWaitsForThePasswordManager() {
  var draft = MCPDraft(serverID: "")
  draft.clientSecret.use(.onePassword)
  draft.clientSecret.reference = "op://vault/item/secret"
  #expect(!draft.checksPasswordManager)
  draft.clientID = "client-1"
  #expect(draft.checksPasswordManager)
}

@Test func externalAuthOffersTheCommandForItsState() {
  let commands = ProviderExternalAuth(
    status: .signedOut, signInCommand: "tool auth login", signOutCommand: "tool auth logout", message: "Not signed in.")
  #expect(commands.copyAction?.command == "tool auth login")
  #expect(commands.copyAction?.label == "Copy Sign-In Command")
  #expect(commands.problem == nil)
  var other = commands
  other.status = .signedIn
  #expect(other.copyAction?.command == "tool auth logout")
  #expect(other.statusLabel == "Signed in")
  other.status = .cliMissing
  #expect(other.copyAction == nil)
  #expect(other.problem == "Not signed in.")
  #expect(other.statusLabel == "Not installed")
  other.status = .error
  #expect(other.copyAction?.command == "tool auth login")
  #expect(other.statusLabel == "Unavailable")
}

@Test func providerStatusUsesTheWebsWords() {
  let managers = [PasswordManager(id: .onePassword, name: "1Password", connected: true)]
  func label(_ provider: ProviderStatus) -> String? { provider.statusLabel(managers: managers) }
  #expect(label(ProviderStatus(provider: "p", configured: false)) == nil)
  #expect(label(ProviderStatus(provider: "p", configured: true)) == "From environment")
  #expect(label(ProviderStatus(provider: "p", configured: true, credentialType: .oauth)) == "Signed in")
  #expect(label(ProviderStatus(provider: "p", configured: true, credentialType: .apiKey)) == "Key saved")
  #expect(label(ProviderStatus(
    provider: "p", configured: true, credentialType: .apiKey,
    apiKey: SecretStatus(configured: true, passwordManager: .onePassword))) == "Key in 1Password")
  #expect(label(ProviderStatus(provider: "p", configured: false, activeLoginId: "l")) == "Signing in…")
  #expect(label(ProviderStatus(
    provider: "p", configured: false, externalAuth: ProviderExternalAuth(status: .signedOut))) == "Not signed in")
}

@Test func providersFilterByNameOrIDAndSortByName() {
  let all = [
    ProviderStatus(provider: "zeta", name: "Alpha", configured: false),
    ProviderStatus(provider: "beta-id", name: "Zed", configured: false),
    ProviderStatus(provider: "gamma", configured: false)
  ]
  #expect(providers(all, matching: "").map(\.provider) == ["zeta", "gamma", "beta-id"])
  #expect(providers(all, matching: " BETA ").map(\.provider) == ["beta-id"])
  #expect(providers(all, matching: "alph").map(\.provider) == ["zeta"])
  #expect(providers(all, matching: "nothing").isEmpty)
}

@Test func theProvidersListDecodesExternalAuth() async throws {
  let body = #"[{"provider":"claude-code","name":"Claude Code","configured":false,"authMethods":[],"#
    + #""credentialType":null,"apiKey":{"configured":false,"passwordManager":null,"reference":null},"#
    + #""activeLoginId":null,"externalAuth":{"status":"signed_out","cliVersion":"1.0.0","#
    + #""signInCommand":"tool auth login","signOutCommand":"tool auth logout","message":"Not signed in."}}]"#
  try await withClient(handler: { _ in StubResponse(body: Data(body.utf8)) }, test: { client in
    let external = try await client.providers().first?.externalAuth
    #expect(external?.status == .signedOut)
    #expect(external?.copyAction?.command == "tool auth login")
  })
}

@Test func clearingAnOAuthAppSendsExplicitNulls() async throws {
  let server = #"{"id":"s","name":"n","url":"https://example.com","enabled":true,"agentId":null,"#
    + #""token":{"configured":false,"passwordManager":null,"reference":null},"oauthClientId":null,"#
    + #""oauthClientSecret":{"configured":false,"passwordManager":null,"reference":null}}"#
  try await withClient(handler: { request in
    guard case .object(let fields) = try requestJSON(request) else { throw URLError(.badURL) }
    #expect(fields["oauthClientId"] == JSONValue.null)
    #expect(fields["oauthClientSecret"] == JSONValue.null)
    return StubResponse(body: Data(server.utf8))
  }, test: { client in
    let saved = try await client.updateMCPServer("s", patch: [
      "oauthClientId": .null, "oauthClientSecret": .null
    ])
    #expect(saved.oauthClientId == nil)
  })
}
