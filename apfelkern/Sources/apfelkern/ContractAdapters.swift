import Foundation
import OpenAPIRuntime

extension Agent {
  init(wire: Components.Schemas.Agent) {
    self.init(
      id: wire.id, name: wire.name, description: wire.description, instructions: wire.instructions,
      avatar: BotAvatarDefinition(wire: wire.avatar, botID: wire.id), enabled: wire.enabled,
      provider: wire.provider, model: wire.model,
      tools: wire.tools,
      webSearchProvider: wire.webSearchProvider.flatMap { WebSearchProvider(rawValue: $0.rawValue) },
      delegates: wire.delegates,
      skills: wire.skills.map { Skill(name: $0.name, instructions: $0.instructions) },
      sharedSkills: wire.sharedSkills, sharedMemory: wire.sharedMemory, mcpServers: wire.mcpServers,
      inference: wire.inference.map {
        Inference(thinkingLevel: $0.thinkingLevel?.rawValue ?? "off", temperature: $0.temperature,
                  maxOutputTokens: $0.maxOutputTokens.flatMap(Int.init(exactly:)))
      },
      desktopModel: wire.desktopModel.map { DesktopModel(provider: $0.provider, model: $0.model) })
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
      origin: wire.origin.map {
        MessageOrigin(kind: $0.kind, name: $0.name, agentId: $0.agentId, via: $0.via, source: $0.source)
      },
      communication: wire.communication.map {
        BotCommunication(executionId: $0.executionId, fromAgentId: $0.fromAgentId,
                         fromName: $0.fromName, toAgentId: $0.toAgentId, toName: $0.toName,
                         status: $0.status.rawValue)
      }, jobQuestion: wire.jobQuestion.map { JobQuestionEvent(id: $0.id, kind: $0.kind, job: $0.job) },
      heldAction: wire.heldAction.map { HeldActionEvent(id: $0.id, job: $0.job) },
      timestamp: wire.timestamp.flatMap(Int64.init(exactly:)),
      attachments: wire.attachments?.map {
        AttachmentInfo(name: $0.name, mimeType: $0.mimeType, size: Int(exactly: $0.size) ?? 0,
                       kind: $0.kind.rawValue)
      }, toolName: wire.toolName, toolCallId: wire.toolCallId, isError: wire.isError,
      toolDetails: try wire.toolDetails.map { try JSONValue(wire: $0) }, requestId: wire.requestId,
      sources: wire.sources?.map { MessageSource(url: $0.url, title: $0.title) })
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
    self.init(
      id: wire.id, content: wire.content, createdAt: wire.createdAt, updatedAt: wire.updatedAt,
      source: wire.source.map {
        MemorySource(kind: $0.kind.rawValue, name: $0.name, scheduleId: $0.scheduleId,
                     agentId: $0.agentId, groupId: $0.groupId)
      })
  }
}

extension SharedSkill {
  init(wire: Components.Schemas.Skill) {
    self.init(id: wire.id, name: wire.name, instructions: wire.instructions, source: "shared")
  }

  init(wire: Components.Schemas.ListedSkill) {
    switch wire {
    case .case1(let value):
      self.init(wire: value.value1)
      description = value.value2.description ?? ""
      origin = value.value2.origin.map(SkillOrigin.init(wire:))
      update = value.value2.update.map(SkillUpdate.init(wire:))
    case .case2(let value):
      self.init(id: value.id, name: value.name, instructions: value.instructions,
                source: value.source.rawValue, path: value.path, description: value.description ?? "")
    }
  }
}

extension Schedule {
  init(wire: Components.Schemas.Schedule) {
    self.init(id: wire.id, agentId: wire.agentId, name: wire.name, cron: wire.cron,
              prompt: wire.prompt, kind: ScheduleKind(wire: wire.kind), command: wire.command,
              timeoutSeconds: wire.timeoutSeconds, notify: wire.notify, timezone: wire.timezone,
              runAt: wire.runAt, eventSourceId: wire.eventSourceId, enabled: wire.enabled,
              nextRunAt: wire.nextRunAt, createdByAgentId: wire.createdByAgentId)
  }
}

extension ScheduleKind {
  init(wire: Components.Schemas.Schedule.KindPayload) {
    switch wire {
    case .prompt: self = .prompt
    case .script: self = .script
    }
  }
}

extension ScriptRun {
  init(wire: Components.Schemas.ScriptRun) {
    self.init(id: wire.id, scheduleId: wire.scheduleId, agentId: wire.agentId, command: wire.command,
              status: ScriptRunStatus(wire: wire.status), exitCode: wire.exitCode, output: wire.output,
              droppedBytes: wire.droppedBytes, error: wire.error, startedAt: wire.startedAt,
              finishedAt: wire.finishedAt)
  }
}

extension ScriptRunStatus {
  init(wire: Components.Schemas.ScriptRun.StatusPayload) {
    switch wire {
    case .running: self = .running
    case .succeeded: self = .succeeded
    case .failed: self = .failed
    case .timedOut: self = .timedOut
    case .interrupted: self = .interrupted
    }
  }
}

extension Execution {
  init(wire: Components.Schemas.Execution) {
    self.init(id: wire.id, agentId: wire.agentId, conversationId: wire.conversationId,
              scheduleId: wire.scheduleId, status: wire.status.rawValue, prompt: wire.prompt, error: wire.error,
              createdAt: wire.createdAt, updatedAt: wire.updatedAt)
  }
}

extension MCPServer {
  init(wire: Components.Schemas.McpServer) {
    self.init(
      id: wire.id, name: wire.name, url: wire.url, enabled: wire.enabled, agentId: wire.agentId,
      auth: wire.token.configured ? "token" : nil, token: SecretStatus(wire: wire.token),
      oauthClientId: wire.oauthClientId, oauthClientSecret: SecretStatus(wire: wire.oauthClientSecret))
  }

  init(wire: Components.Schemas.McpServerStatus) {
    self.init(wire: wire.value1)
    authenticated = wire.value2.authenticated
    auth = wire.value2.auth.rawValue
  }
}
