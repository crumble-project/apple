import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  @MainActor @Test func profileEditAppearsImmediatelyAndFailurePreservesNewerDraft() async {
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
    for _ in 0..<100 where model.loading { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.loading)
    #expect(model.agents.first?.name == "Before")
    #expect(model.agentDraft?.name == "Newer draft")
  }

  @MainActor @Test func agentCreationUsesProvisionalRowWithoutStealingNavigation() async {
    let model = AppModel(
      client: StubProtocol.client { request in
        request.httpMethod == "POST"
          ? (201, ContractFixtures.json(ContractFixtures.agent("created", name: "New bot").value1)) : (404, "")
      })
    model.route = .memory
    model.agentDraft = AgentDraft(isNew: true, agentID: "", name: "New bot")
    model.saveAgentEditor()
    #expect(model.agents.first?.id.hasPrefix("pending:") == true)
    #expect(model.agentDraft == nil)
    model.route = .skills
    for _ in 0..<100 where model.loading { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(model.agents.map(\.id) == ["created"])
    #expect(model.route == .skills)
  }

  @MainActor @Test func failedAgentDeleteRestoresOnlyRemovedRow() async {
    let model = AppModel(client: StubProtocol.client { _ in (500, #"{"error":"busy"}"#) })
    model.agents = [Agent(id: "a1", name: "First"), Agent(id: "a2", name: "Second")]
    model.route = .memory
    model.agentDraft = AgentDraft(isNew: false, agentID: "a1", name: "First")
    model.deleteSelected()
    #expect(model.agents.map(\.id) == ["a2"])
    model.agents[0].name = "Second updated"
    for _ in 0..<100 where model.loading { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(model.agents.map(\.id) == ["a1", "a2"])
    #expect(model.agents[1].name == "Second updated")
    #expect(model.route == .memory)
  }

  @MainActor @Test func aProviderSignInRefreshesTheEditorsModelsAndTheModelChoices() async throws {
    let model = AppModel(
      client: StubProtocol.client { request in
        switch request.url?.path {
        case "/v1/models":
          (200, #"[{"provider":"openai","id":"gpt-new","name":"New","contextWindow":1,"reasoning":false,"#
            + #""thinkingLevels":[]}]"#)
        case "/v1/judge-model": (200, #"{"judgeModel":null,"effective":null,"choices":[]}"#)
        case "/v1/vision-model":
          (200, #"{"visionModel":null,"choices":[{"provider":"openai","model":"gpt-new","name":"New"}]}"#)
        default: (200, "[]")
        }
      })
    model.agentDraft = AgentDraft(isNew: false, agentID: "a1", provider: "openai")
    model.handleProviderLogin(.signedIn(provider: "openai"))
    let services = model.connectedServices
    for _ in 0..<200 where model.models.isEmpty || services.visionModel.setting == nil
        || services.judgeModel.setting == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.models.map(\.id) == ["gpt-new"])
    #expect(services.visionModel.setting?.choices.map(\.name) == ["New"])
    #expect(services.judgeModel.setting != nil)
  }
}
