import Foundation
import OpenAPIRuntime

extension Agent {
  init(wire: Components.Schemas.Agent) {
    self.init(
      id: wire.id, name: wire.name, description: wire.description, instructions: wire.instructions,
      avatar: wire.avatar, enabled: wire.enabled, provider: wire.provider, model: wire.model,
      tools: wire.tools, delegates: wire.delegates,
      skills: wire.skills.map { Skill(name: $0.name, instructions: $0.instructions) },
      sharedSkills: wire.sharedSkills, sharedMemory: wire.sharedMemory, mcpServers: wire.mcpServers,
      inference: wire.inference.map {
        Inference(thinkingLevel: $0.thinkingLevel?.rawValue ?? "off", temperature: $0.temperature,
                  maxOutputTokens: $0.maxOutputTokens.flatMap(Int.init(exactly:)))
      })
  }

  init(wire: Components.Schemas.AgentPreview) {
    self.init(wire: wire.value1)
    lastMessage = wire.value2.lastMessage
  }
}

extension JSONValue {
  init(wire: some Encodable) throws {
    self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(wire))
  }
}

extension Message {
  init(wire: Components.Schemas.TranscriptMessage) throws {
    self.init(
      id: wire.id, entryId: wire.entryId, role: wire.role, content: .string(wire.content),
      blocks: try wire.blocks.map { try JSONValue(wire: $0) }, kind: wire.kind,
      replyTo: wire.replyTo, replyPreview: wire.replyPreview,
      origin: wire.origin.map { MessageOrigin(kind: $0.kind, name: $0.name, agentId: $0.agentId) },
      communication: wire.communication.map {
        BotCommunication(executionId: $0.executionId, fromAgentId: $0.fromAgentId,
                         fromName: $0.fromName, toAgentId: $0.toAgentId, toName: $0.toName,
                         status: $0.status.rawValue)
      }, timestamp: wire.timestamp.flatMap(Int64.init(exactly:)),
      attachments: wire.attachments?.map {
        AttachmentInfo(name: $0.name, mimeType: $0.mimeType, size: Int(exactly: $0.size) ?? 0,
                       kind: $0.kind.rawValue)
      }, toolName: wire.toolName, toolCallId: wire.toolCallId, isError: wire.isError,
      toolDetails: try wire.toolDetails.map { try JSONValue(wire: $0) }, requestId: wire.requestId)
  }
}

extension ChatSnapshot {
  init(wire: Components.Schemas.ChatSnapshot) throws {
    self.init(
      messages: try wire.value1.messages.map(Message.init(wire:)), status: wire.value2.status.rawValue,
      partial: wire.value2.partial, error: wire.value2.error, agentId: wire.value2.agentId,
      hasMore: wire.value1.hasMore, oldestEntryId: wire.value1.oldestEntryId)
  }
}

extension ChatHistoryResponse {
  init(wire: Components.Schemas.TranscriptPage) throws {
    self.init(messages: try wire.messages.map(Message.init(wire:)), hasMore: wire.hasMore,
              oldestEntryId: wire.oldestEntryId)
  }
}

extension Memory {
  init(wire: Components.Schemas.Memory) {
    self.init(id: wire.id, content: wire.content, createdAt: wire.createdAt)
  }
}

extension SharedSkill {
  init(wire: Components.Schemas.Skill) {
    self.init(id: wire.id, name: wire.name, instructions: wire.instructions)
  }

  init(wire: Components.Schemas.ListedSkill) {
    switch wire {
    case .case1(let value):
      self.init(wire: value.value1)
      source = value.value2.source.rawValue
    case .case2(let value):
      self.init(id: value.id, name: value.name, instructions: value.instructions,
                source: value.source.rawValue, path: value.path)
    }
  }
}

extension Schedule {
  init(wire: Components.Schemas.Schedule) {
    self.init(id: wire.id, agentId: wire.agentId, name: wire.name, cron: wire.cron,
              prompt: wire.prompt, timezone: wire.timezone, runAt: wire.runAt, enabled: wire.enabled,
              createdByAgentId: wire.createdByAgentId)
  }
}

extension Execution {
  init(wire: Components.Schemas.Execution) {
    self.init(id: wire.id, agentId: wire.agentId, conversationId: wire.conversationId,
              status: wire.status.rawValue, prompt: wire.prompt, error: wire.error,
              createdAt: wire.createdAt, updatedAt: wire.updatedAt)
  }
}

extension MCPServer {
  init(wire: Components.Schemas.McpServer) {
    self.init(id: wire.id, name: wire.name, url: wire.url, enabled: wire.enabled, agentId: wire.agentId)
  }

  init(wire: Components.Schemas.McpServerStatus) {
    self.init(wire: wire.value1)
    authenticated = wire.value2.authenticated
    auth = wire.value2.auth.rawValue
  }
}
