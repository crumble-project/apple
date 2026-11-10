import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  @MainActor @Test func savingTheEditorLeavesSkillsAndAssignmentsAlone() async throws {
    let model = AppModel(
      client: StubProtocol.client { _ in (200, ContractFixtures.json(ContractFixtures.agent("a1").value1)) })
    model.agents = [Agent(id: "a1", name: "Atlas", model: "example")]
    var draft = AgentDraft(agent: model.agents[0])
    draft.skills = [Skill(name: "Stale", instructions: "From when the editor opened")]
    draft.sharedSkills = ["stale"]
    model.agentDraft = draft
    model.agents[0].sharedSkills = ["newer"]
    model.saveAgentEditor()
    #expect(model.agents[0].sharedSkills == ["newer"])
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    let patch = try #require(StubProtocol.requests.first { $0.httpMethod == "PATCH" })
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(patch.httpBody))
    guard case .object(let fields) = body else { throw URLError(.cannotDecodeRawData) }
    #expect(fields["skills"] == nil && fields["sharedSkills"] == nil)
  }

  @MainActor @Test func failedBotSkillSaveRestoresDraftInTheEditor() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        if request.httpMethod == "POST" { Thread.sleep(forTimeInterval: 0.05); return (500, #"{"error":"busy"}"#) }
        return (200, "[]")
      })
    model.agents = [Agent(id: "a1", name: "Atlas")]
    model.agentDraft = AgentDraft(agent: model.agents[0])
    model.openPersonalSkillForm(agentID: "a1")
    model.skillDraft?.name = "Edited"
    model.skillDraft?.instructions = "New instructions"
    model.saveSkill()
    #expect(model.skillDraft == nil)
    #expect(model.botSkillBoard.skills(agentID: "a1").map(\.name) == ["Edited"])
    while !model.botSkillBoard.pending.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.botSkillBoard.skills(agentID: "a1").isEmpty)
    #expect(model.skillDraft?.name == "Edited")
    #expect(model.skillDraft?.instructions == "New instructions")
    #expect(model.errorText.contains("busy"))
    model.botSkillBoard.reset()
  }

  @MainActor @Test func failedSharedSkillAssignmentPreservesNewerAgentFields() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        if request.url?.path == "/v1/skills/s1/assignment" {
          Thread.sleep(forTimeInterval: 0.05)
          return (500, #"{"error":"busy"}"#)
        }
        return (404, "")
      })
    model.agents = [Agent(id: "a1", name: "Atlas", description: "Keep me")]
    model.sharedSkills = [
      SharedSkill(id: "s1", name: "Writing", instructions: "Write clearly", source: "shared", path: nil)
    ]
    model.setSharedSkill("s1", for: "a1", enabled: true)
    model.agents[0].name = "Atlas renamed while saving"
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.agents[0].name == "Atlas renamed while saving")
    #expect(model.agents[0].description == "Keep me")
    #expect(model.agents[0].sharedSkills?.isEmpty != false)
    #expect(model.errorText.contains("busy"))
  }

  @MainActor @Test func memoryCreateAppearsBeforeServerResponseAndReconciles() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        request.httpMethod == "POST" && request.url?.path == "/v1/memories"
          ? (201, ContractFixtures.json(ContractFixtures.memory("m1", content: "Remember this"))) : (404, "")
      })
    model.route = .memory
    model.openMemoryForm("")
    model.memoryDraft?.content = "Remember this"
    model.saveMemory()
    #expect(model.memoryDraft == nil)
    #expect(model.route == .memory)
    #expect(model.sharedMemories.count == 1)
    #expect(model.sharedMemories[0].id.hasPrefix("pending-memory-"))
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.sharedMemories.map(\.id) == ["m1"])
    #expect(model.route == .memory)
    #expect(model.errorText.isEmpty)
  }

  @MainActor @Test func failedMemoryDeleteRestoresOnlyDeletedRecord() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        request.httpMethod == "DELETE" ? (500, #"{"error":"busy"}"#) : (404, "")
      })
    model.route = .memory
    model.sharedMemories = [
      Memory(id: "m1", content: "First"), Memory(id: "m2", content: "Second")
    ]
    model.deleteMemory("m1")
    #expect(model.sharedMemories.map(\.id) == ["m2"])
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.sharedMemories.map(\.id) == ["m1", "m2"])
    #expect(model.sharedMemories.map(\.content) == ["First", "Second"])
    #expect(model.errorText.contains("busy"))
  }

  @MainActor @Test func failedMemorySaveDoesNotReplaceNewerDraft() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        request.httpMethod == "POST" ? (500, #"{"error":"busy"}"#) : (404, "")
      })
    model.route = .memory
    model.openMemoryForm("")
    model.memoryDraft?.content = "Old draft"
    model.saveMemory()
    model.openMemoryForm("")
    model.memoryDraft?.content = "Newer draft"
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.memoryDraft?.content == "Newer draft")
    #expect(model.sharedMemories.isEmpty)
    #expect(model.errorText.contains("busy"))
  }

  @MainActor @Test func aLateBotListKeepsASavedAvatar() async throws {
    let (client, controller) = ControlledDeliveryProtocol.client()
    let model = AppModel(client: client)
    let bot = Agent(id: "a1", name: "Atlas")
    model.agents = [bot]
    await controller.hold("/v1/agents")
    await controller.hold("/v1/agents/a1")
    model.refresh()
    #expect(await controller.waitForHeld("/v1/agents"))

    model.avatarBoard.select(bot)
    var edited = bot.avatar
    edited.color = "#112233"
    model.avatarBoard.value = edited
    model.saveAvatar()
    #expect(model.agents[0].avatar.color == "#112233")
    #expect(await controller.waitForHeld("/v1/agents/a1"))
    await controller.release("/v1/agents/a1", body: try agentJSON(avatar: edited))
    while !model.avatarBoard.saved { try await Task.sleep(for: .milliseconds(5)) }

    await controller.release("/v1/agents", body: "[" + (try agentJSON(avatar: bot.avatar)) + "]")
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.agents.first?.avatar.color == "#112233")
  }

  @MainActor @Test func aFailedAvatarSaveRollsBackWithoutABanner() async throws {
    let client = StubProtocol.client { request in
      request.httpMethod == "PATCH" ? (500, #"{"error":"busy"}"#) : (404, "")
    }
    let model = AppModel(client: client)
    let bot = Agent(id: "a1", name: "Atlas")
    model.agents = [bot]
    model.avatarBoard.select(bot)
    var edited = bot.avatar
    edited.color = "#112233"
    model.avatarBoard.value = edited

    model.saveAvatar()
    #expect(model.agents[0].avatar.color == "#112233")
    while model.avatarBoard.isSaving { try await Task.sleep(for: .milliseconds(5)) }

    #expect(model.agents[0].avatar.color == bot.avatar.color)
    #expect(model.avatarBoard.value.color == "#112233")
    #expect(model.avatarBoard.saveError.contains("busy"))
    #expect(model.errorText.isEmpty)
    #expect(model.pendingMutations.isEmpty)
  }

  @MainActor @Test func aConnectionFinishingAfterSignOutIsDropped() async throws {
    let (client, controller) = ControlledDeliveryProtocol.client()
    let model = AppModel(client: client)
    model.serverURL = client.baseURL
    model.token = "made-up-token"
    await controller.hold("/v1/agents")
    model.saveSettings()
    #expect(await controller.waitForHeld("/v1/agents"))

    // What sign-out does, without touching this machine's Keychain.
    model.token = ""
    model.applyConnection(APIClient(baseURL: client.baseURL, token: "", session: client.session))
    await controller.release("/v1/agents", body: "[]")
    while model.savingConnection { try await Task.sleep(for: .milliseconds(5)) }

    #expect(model.token.isEmpty)
    #expect(model.client?.token.isEmpty == true)
    #expect(model.notice.isEmpty)
  }
}

private func agentJSON(avatar: BotAvatarDefinition) throws -> String {
  let agent = Data(ContractFixtures.json(ContractFixtures.agent("a1").value1).utf8)
  var fields = try JSONDecoder().decode([String: JSONValue].self, from: agent)
  fields["avatar"] = try JSONValue(encoding: avatar)
  return JSONValue.object(fields).prettyPrinted
}
