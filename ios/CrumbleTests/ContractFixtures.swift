import apfelkern
import Foundation
import Testing

enum ContractFixtures {
  static let timestamp = "2026-01-01T00:00:00.000Z"
  static let requestID = "00000000-0000-4000-8000-000000000001"

  static func json<Value: Encodable>(_ value: Value) -> String {
    do {
      let data = try JSONEncoder().encode(value)
      guard let json = String(data: data, encoding: .utf8) else {
        Issue.record("Contract fixture is not UTF-8")
        return ""
      }
      return json
    } catch {
      Issue.record("Could not encode contract fixture: \(error)")
      return ""
    }
  }

  static func agent(_ id: String, name: String = "Atlas", lastMessage: String? = nil)
    -> Components.Schemas.AgentPreview {
    .init(value1: .init(
      avatar: "", createdAt: timestamp, delegates: [], description: "", enabled: true,
      id: id, instructions: "", mcpServers: [], model: "test-model", name: name,
      provider: "test-provider", skills: [], tools: [], updatedAt: timestamp),
      value2: .init(lastMessage: lastMessage))
  }

  static func memory(_ id: String, content: String, agentID: String? = nil) -> Components.Schemas.Memory {
    .init(agentId: agentID, content: content, createdAt: timestamp, id: id, updatedAt: timestamp)
  }

  static func snapshot(_ agentID: String, status: Components.Schemas.ChatSnapshot.Value2Payload.StatusPayload = .idle,
                       messages: [Components.Schemas.TranscriptMessage] = []) -> String {
    json(Components.Schemas.ChatSnapshot(
      value1: .init(hasMore: false, messages: messages),
      value2: .init(agentId: agentID, conversation: .init(
        agentId: agentID, createdAt: timestamp, id: "conversation-\(agentID)", title: "Chat",
        updatedAt: timestamp), conversationId: "conversation-\(agentID)", partial: "",
        status: status, updatedAt: 0)))
  }

  static func execution(_ agentID: String = "a1", requestID: String = requestID) -> String {
    json(Components.Schemas.Execution(
      agentId: agentID, conversationId: "conversation-\(agentID)", createdAt: timestamp,
      id: "execution-1", prompt: "hello", requestId: requestID, status: .pending, updatedAt: timestamp))
  }
}
