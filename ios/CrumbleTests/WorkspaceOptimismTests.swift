import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  @MainActor @Test func failedPersonalSkillSaveRestoresDraftAndPreservesNewerAgentFields() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        if request.httpMethod == "PATCH" { Thread.sleep(forTimeInterval: 0.05); return (500, #"{"error":"busy"}"#) }
        return (404, "")
      })
    let existing = Skill(name: "Old", instructions: "Keep this")
    model.agents = [Agent(id: "a1", name: "Atlas", description: "Keep me", skills: [existing])]
    model.route = .skills
    model.openPersonalSkillForm(agentID: "a1", skillID: existing.id.uuidString)
    model.skillDraft?.name = "Edited"
    model.skillDraft?.instructions = "New instructions"
    model.saveSkill()
    model.agents[0].name = "Atlas renamed while saving"
    while model.loading { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.agents[0].name == "Atlas renamed while saving")
    #expect(model.agents[0].description == "Keep me")
    #expect(model.agents[0].skills?.first?.name == "Old")
    #expect(model.skillDraft?.name == "Edited")
    #expect(model.skillDraft?.instructions == "New instructions")
    #expect(model.errorText.contains("busy"))
  }

  @MainActor @Test func failedSharedSkillAssignmentPreservesNewerAgentFields() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        if request.httpMethod == "PATCH" { Thread.sleep(forTimeInterval: 0.05); return (500, #"{"error":"busy"}"#) }
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
}
