import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    @MainActor @Test func memoryOverviewLoadsEveryBotWithoutSelectingOne() async throws {
        let client = StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/agents": (200, #"[{"id":"a1","name":"Atlas"},{"id":"a2","name":"Beacon"}]"#)
            case "/v1/memories": (200, #"[{"id":"shared","content":"For every bot"}]"#)
            case "/v1/agents/a1/memories": (200, #"[{"id":"personal-1","content":"Only Atlas"}]"#)
            case "/v1/agents/a2/memories": (200, #"[{"id":"personal-2","content":"Only Beacon"}]"#)
            default: (404, "")
            }
        }
        let model = AppModel(client: client)
        model.openPanel(.memory)
        for _ in 0..<100 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.loading)
        #expect(model.route == .memory)
        #expect(model.selectedAgentID.isEmpty)
        #expect(model.agents.map(\.id) == ["a1", "a2"])
        #expect(model.agentMemories["a1"]?.map(\.id) == ["personal-1"])
        #expect(model.agentMemories["a2"]?.map(\.id) == ["personal-2"])
        #expect(model.sharedMemories.map(\.id) == ["shared"])
        #expect(model.errorText.isEmpty)
        #expect(StubProtocol.requests.allSatisfy { $0.url?.path.contains("/chat") == false })
    }

    @MainActor @Test func memoryActionsUseTheEntryOwnerWithoutAnActiveBot() async throws {
        let client = StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/agents": (200, #"[{"id":"a2","name":"Beacon"}]"#)
            case "/v1/memories", "/v1/agents/a2/memories": (200, "[]")
            case "/v1/agents/a2/memories/m2":
                request.httpMethod == "DELETE" ? (204, "") : (200, #"{"id":"m2","content":"Updated"}"#)
            default: (404, "")
            }
        }
        let model = AppModel(client: client)
        model.agentMemories = ["a2": [Memory(id: "m2", content: "Only Beacon")]]
        model.openMemoryForm("m2", agentID: "a2")
        #expect(model.memoryDraft?.content == "Only Beacon")
        #expect(model.memoryDraft?.agentID == "a2")
        model.memoryDraft?.content = "Updated"
        model.saveMemory()
        for _ in 0..<100 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.deleteMemory("m2", agentID: "a2")
        for _ in 0..<100 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.loading)
        #expect(model.errorText.isEmpty)
        #expect(model.selectedAgentID.isEmpty)
        let writes = StubProtocol.requests.filter { ["PATCH", "DELETE"].contains($0.httpMethod ?? "") }
        #expect(writes.compactMap { $0.url?.path } == ["/v1/agents/a2/memories/m2", "/v1/agents/a2/memories/m2"])
    }

    @MainActor @Test func failedPersonalSkillSaveRestoresDraftWithoutReplacingNewerAgentFields() async throws {
        let client = StubProtocol.client { request in
            request.httpMethod == "PATCH" ? (500, #"{"error":"busy"}"#) : (200, "[]")
        }
        let skill = Skill(name: "Old", instructions: "Old instructions")
        let model = AppModel(client: client)
        model.route = .skills
        model.agents = [Agent(id: "a1", name: "Atlas", skills: [skill])]
        model.openPersonalSkillForm(agentID: "a1", skillID: skill.id.uuidString)
        model.skillDraft?.name = "Updated"
        model.skillDraft?.instructions = "Updated instructions"
        model.saveSkill()
        model.agents[0].name = "Atlas renamed while saving"
        while model.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.agents[0].name == "Atlas renamed while saving")
        #expect(model.agents[0].skills?.first?.name == "Old")
        #expect(model.skillDraft?.name == "Updated")
        #expect(model.errorText.contains("busy"))
    }

    @MainActor @Test func failedSharedSkillAssignmentRestoresMembershipWithoutReplacingNewerAgentFields() async throws {
        let client = StubProtocol.client { request in
            request.httpMethod == "PATCH" ? (500, #"{"error":"busy"}"#) : (200, "[]")
        }
        let model = AppModel(client: client)
        model.agents = [Agent(id: "a1", name: "Atlas", sharedSkills: [])]
        model.setSharedSkill("s1", for: "a1", enabled: true)
        model.agents[0].name = "Atlas renamed while saving"
        while model.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.agents[0].name == "Atlas renamed while saving")
        #expect(model.agents[0].sharedSkills == [])
        #expect(model.errorText.contains("busy"))
    }
}
