import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    @MainActor private func saveAndCapturePatch(
        _ model: AppModel, sent: () -> [String: Any]?
    ) async throws -> [String: Any] {
        model.saveAgentEditor()
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(sent())
    }

    @MainActor @Test func theBotDesktopToggleFollowsCapabilitiesButKeepsAnExistingDesktop() async {
        let model = AppModel(client: StubProtocol.client { request in
            request.url?.path == "/v1/capabilities" ? (200, #"{"coding":false,"desktop":true}"#) : (404, "")
        })
        let plain = AgentDraft(isNew: false, agentID: "a1")
        let desk = AgentDraft(isNew: false, agentID: "a1", toolsDesktop: true)
        #expect(!model.offersDesktop(for: plain))
        #expect(model.offersDesktop(for: desk))
        model.loadCapabilities()
        for _ in 0..<100 where model.capabilities == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.offersDesktop(for: plain))
    }

    @MainActor @Test func theEditorSavesTheDesktopToolAndModel() async throws {
        nonisolated(unsafe) var sent: [String: Any]?
        let model = AppModel(client: StubProtocol.client { request in
            guard request.httpMethod == "PATCH" else { return (404, "") }
            sent = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            return (200, agentFixture(#"{"id":"a1","name":"Desk","enabled":true,"tools":["desktop"]}"#))
        })
        model.agents = [Agent(id: "a1", name: "Desk", tools: [])]
        model.openEditor(agentID: "a1")
        model.agentDraft?.toolsDesktop = true
        model.agentDraft?.desktopProvider = "opencode-go"
        model.agentDraft?.desktopModel = "gpt-6-luna"

        let patch = try await saveAndCapturePatch(model) { sent }

        #expect((patch["tools"] as? [String])?.contains("desktop") == true)
        #expect(patch["desktopModel"] as? [String: String] == ["provider": "opencode-go", "model": "gpt-6-luna"])
    }

    @MainActor @Test func clearingTheDesktopModelSendsNull() async throws {
        nonisolated(unsafe) var sent: [String: Any]?
        let model = AppModel(client: StubProtocol.client { request in
            guard request.httpMethod == "PATCH" else { return (404, "") }
            sent = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            return (200, agentFixture(#"{"id":"a1","name":"Desk","enabled":true,"tools":["desktop"]}"#))
        })
        model.agents = [
            Agent(
                id: "a1", name: "Desk", tools: ["desktop"],
                desktopModel: DesktopModel(provider: "opencode-go", model: "gpt-6-luna"))
        ]
        model.openEditor(agentID: "a1")
        #expect(model.agentDraft?.desktopModel == "gpt-6-luna")
        model.agentDraft?.desktopProvider = ""
        model.agentDraft?.desktopModel = ""

        let patch = try await saveAndCapturePatch(model) { sent }

        #expect(patch["desktopModel"] is NSNull)
    }
}
