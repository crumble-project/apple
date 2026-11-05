import apfelkern
import Foundation
import Testing

@testable import Crumble

struct DesktopKeyboardTests {
  @Test func textBecomesOneKeyPerCharacter() {
    #expect(DesktopKeyboard.keys(for: "aé") == ["a", "é"])
  }

  @Test func lineBreaksAndTabsBecomeTheirKeys() {
    #expect(DesktopKeyboard.keys(for: "a\nb\tc") == ["a", "Enter", "b", "Tab", "c"])
  }

  @Test func charactersNoVNCCantSendAreDropped() {
    #expect(DesktopKeyboard.keys(for: "a😀b") == ["a", "b"])
  }
}

extension APIClientTests {
  @MainActor private func patch(of model: AppModel, sent: () -> [String: Any]?) async throws -> [String: Any] {
    model.saveAgentEditor()
    for _ in 0..<200 where sent() == nil { try await Task.sleep(for: .milliseconds(10)) }
    return try #require(sent())
  }

  @MainActor @Test func savingABotKeepsItsBotDesktopAndCodingJobs() async throws {
    nonisolated(unsafe) var sent: [String: Any]?
    let model = AppModel(
      client: StubProtocol.client { request in
        guard request.httpMethod == "PATCH" else { return (404, "") }
        sent = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        return (500, #"{"error":"busy"}"#)
      })
    model.agents = [
      Agent(
        id: "a1", name: "Desk", tools: ["memory", "desktop", "coding"],
        desktopModel: DesktopModel(provider: "opencode-go", model: "gpt-6-luna"))
    ]
    model.openEditor(agentID: "a1")

    let saved = try await patch(of: model) { sent }

    #expect(saved["tools"] as? [String] == ["memory", "coding", "desktop"])
    #expect(saved["desktopModel"] as? [String: String] == ["provider": "opencode-go", "model": "gpt-6-luna"])
  }

  @MainActor @Test func theBotDesktopToggleFollowsCapabilitiesButKeepsAnExistingDesktop() async {
    let model = AppModel(
      client: StubProtocol.client { request in
        request.url?.path == "/v1/capabilities"
          ? (200, #"{"coding":false,"desktop":true,"jobKinds":["desktop"]}"#) : (404, "")
      })
    let plain = AgentDraft(isNew: false, agentID: "a1")
    let desk = AgentDraft(isNew: false, agentID: "a1", toolsDesktop: true)
    #expect(!model.offersDesktop(for: plain))
    #expect(model.offersDesktop(for: desk))
    model.loadCapabilities()
    for _ in 0..<100 where model.capabilities == nil { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(model.offersDesktop(for: plain))
  }
}

@Test func aDesktopJobsNotificationOpensTheBotDesktop() {
  let payload = NotificationPayload(userInfo: [
    "type": "reply", "agentId": "a1", "agentName": "Desk", "serverId": "s1", "eventId": "e1",
    "origin": "desktop", "preview": "Please log in.", "createdAt": ContractFixtures.timestamp
  ])
  var router = NotificationTapRouter()
  router.queue(payload)
  #expect(router.resolve(serverID: "s1", serverURL: nil, agentIDs: ["a1"]) == .openDesktop("a1"))
}
