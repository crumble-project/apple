import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    @MainActor @Test func profileEditAppearsImmediatelyAndFailurePreservesNewerDraft() async throws {
        let model = AppModel(
            client: StubProtocol.client { request in
                request.httpMethod == "PATCH" ? (500, #"{"error":"busy"}"#) : (404, "")
            })
        model.agents = [Agent(id: "a1", name: "Before", lastMessage: "Latest reply")]
        model.route = .memory
        model.agentDraft = AgentDraft(isNew: false, agentID: "a1", name: "After")
        model.saveAgentEditor()
        #expect(model.agents.first?.name == "After")
        #expect(model.agents.first?.lastMessage == "Latest reply")
        #expect(model.agentDraft == nil)
        model.agentDraft = AgentDraft(isNew: false, agentID: "a1", name: "Newer draft")
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.loading)
        #expect(model.agents.first?.name == "Before")
        #expect(model.agentDraft?.name == "Newer draft")
    }

    @MainActor @Test func profileEditKeepsToolsTheEditorDoesNotManage() async throws {
        nonisolated(unsafe) var sentTools: [String]?
        let model = AppModel(
            client: StubProtocol.client { request in
                guard request.httpMethod == "PATCH" else { return (404, "") }
                let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                sentTools = body?["tools"] as? [String]
                return (200, #"{"id":"a1","name":"After","enabled":true,"tools":["memory","coding"]}"#)
            })
        model.agents = [Agent(id: "a1", name: "Before", tools: ["memory", "coding"])]
        model.openEditor(agentID: "a1")
        model.agentDraft?.name = "After"
        model.saveAgentEditor()
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sentTools == ["memory", "coding"])
    }

    @MainActor @Test func agentCreationUsesProvisionalRowWithoutStealingNavigation() async throws {
        let model = AppModel(
            client: StubProtocol.client { request in
                request.httpMethod == "POST" ? (201, #"{"id":"created","name":"New bot","enabled":true}"#) : (404, "")
            })
        model.route = .memory
        model.agentDraft = AgentDraft(isNew: true, agentID: "", name: "New bot")
        model.saveAgentEditor()
        #expect(model.agents.first?.id.hasPrefix("pending:") == true)
        #expect(model.agentDraft == nil)
        model.route = .skills
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.loading)
        #expect(model.agents.map(\.id) == ["created"])
        #expect(model.route == .skills)
    }

    @MainActor @Test func failedAgentDeleteRestoresOnlyRemovedRow() async throws {
        let model = AppModel(client: StubProtocol.client { _ in (500, #"{"error":"busy"}"#) })
        model.agents = [Agent(id: "a1", name: "First"), Agent(id: "a2", name: "Second")]
        model.route = .memory
        model.agentDraft = AgentDraft(isNew: false, agentID: "a1", name: "First")
        model.deleteSelected()
        #expect(model.agents.map(\.id) == ["a2"])
        model.agents[0].name = "Second updated"
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.loading)
        #expect(model.agents.map(\.id) == ["a1", "a2"])
        #expect(model.agents[1].name == "Second updated")
        #expect(model.route == .memory)
    }
}
