import Foundation
import OpenBotAvatar
import Testing

@testable import apfelkern

/// The validator normalizes what it reads, so a catalog definition is compared in that form.
private func normalized(_ id: String) throws -> AvatarDefinition {
  try #require(AvatarCatalog.definition(id: id)).validated().get()
}

private func mug() throws -> AvatarDefinition { try normalized("mug") }

private func agentJSON(_ avatar: BotAvatarDefinition) throws -> Data {
  let encoded = try #require(String(data: JSONEncoder().encode(avatar), encoding: .utf8))
  return Data(#"""
    {"id":"bot","name":"Bot","avatar":\#(encoded),"description":"","instructions":"","provider":"openai",
     "model":"gpt-4.1","enabled":true,"tools":[],"skills":[],"mcpServers":[],"delegates":[],
     "createdAt":"now","updatedAt":"now"}
    """#.utf8)
}

@Test func theDefaultAvatarMatchesTheServersHash() {
  // defaultAvatarDefinition in bot/apps/server/src/contract/avatar.ts: 31 * h + code point.
  var hash: UInt32 = 0
  for scalar in "a1😀".unicodeScalars { hash = hash &* 31 &+ scalar.value }
  let avatar = BotAvatarDefinition.default(for: "a1😀")
  #expect(avatar.definition == AvatarCatalog.examples[Int(hash) % AvatarCatalog.examples.count])
  #expect(avatar.color == "#ff6a1a")
  #expect(avatar.eyeColor == "#151515")
}

@Test func everyCatalogAvatarIsValid() {
  #expect(AvatarCatalog.all.count == 22)
  for definition in AvatarCatalog.all {
    #expect((try? definition.validated().get()) != nil, "\(definition.id)")
  }
}

@Test func anInvalidDefinitionFromTheServerFallsBackToTheStarter() async throws {
  var invalid = BotAvatarDefinition(definition: try mug(), color: "#112233", eyeColor: "#445566")
  invalid.definition.body.path = "not a path"
  let response = try agentJSON(invalid)
  try await withClient(handler: { _ in StubResponse(body: response) }) { client in
    let agent = try await client.updateAgent("bot", patch: ["name": .string("Bot")])
    #expect(agent.avatar.definition == BotAvatarDefinition.default(for: "bot").definition)
    #expect(agent.avatar.color == "#112233")
  }
}

@Test func creatingAnAgentSendsAndReadsItsAvatar() async throws {
  let avatar = BotAvatarDefinition(definition: try mug(), color: "#1fbf68", eyeColor: "#ffffff")
  let response = try agentJSON(avatar)
  try await withClient(handler: { request in
    let body = try requestJSON(request)
    let expected = try JSONValue(encoding: avatar)
    #expect(body["avatar"] == expected)
    return StubResponse(status: 201, body: response)
  }) { client in
    let created = try await client.createAgent(Agent(name: "Bot", avatar: avatar))
    #expect(created.avatar == avatar)
  }
}

@Test func updatingAnAgentSendsItsAvatar() async throws {
  let avatar = BotAvatarDefinition(definition: try mug(), color: "#1fbf68", eyeColor: "#ffffff")
  let response = try agentJSON(avatar)
  try await withClient(handler: { request in
    let body = try requestJSON(request)
    let expected = try JSONValue(encoding: avatar)
    #expect(body["avatar"] == expected)
    return StubResponse(body: response)
  }) { client in
    let saved = try await client.updateAgent("bot", patch: ["avatar": try JSONValue(encoding: avatar)])
    #expect(saved.avatar == avatar)
  }
}

@Test func importingKeepsColorsAndReportsEveryError() throws {
  let current = BotAvatarDefinition(definition: try mug(), color: "#111111", eyeColor: "#222222")
  let barbell = try normalized("barbell")
  let json = try #require(String(data: JSONEncoder().encode(barbell), encoding: .utf8))
  let imported = try current.importing(json: json).get()
  #expect(imported.definition == barbell)
  #expect(imported.color == "#111111")

  guard case .failure(let failure) = current.importing(json: "{}") else {
    Issue.record("Expected a validation failure")
    return
  }
  #expect(!failure.errors.isEmpty)
}

@Test func recoloringAcceptsOnlyTheContractsHexForms() throws {
  let avatar = BotAvatarDefinition(definition: try mug(), color: "#111111", eyeColor: "#222222")
  #expect(avatar.recolored(color: "#AbC", eyeColor: "#123456")?.color == "#AbC")
  #expect(avatar.recolored(color: " #abc", eyeColor: "#123456") == nil)
  #expect(avatar.recolored(color: "#abcd", eyeColor: "#123456") == nil)
  #expect(avatar.recolored(color: "#abc", eyeColor: "white") == nil)
}

@Test func theGenerationPromptEndsWithTheDescription() {
  let prompt = BotAvatarDefinition.generationPrompt("  a watering can \n")
  #expect(prompt.hasPrefix("# Avatar geometry designer"))
  #expect(prompt.hasSuffix("\n\n## User description\n\na watering can\n"))
}
