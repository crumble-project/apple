import apfelkern
import AuthenticationServices
import BotAvatar
import Foundation
import Observation
import SwiftUI
import UIKit

/// The window's state and the actions that change it. Network work runs in tasks that report back
/// on the main actor; results from a replaced connection or a previous agent are dropped.
@MainActor @Observable
final class AppModel {
  /// Localhost works in the simulator. On a physical iPhone use the Mac's LAN address.
  var serverURL = "http://127.0.0.1:7337"
  var token = ""
  private(set) var client: APIClient?
  private(set) var generation = 0

  var agents: [Agent] = []
  var route: Route?
  private(set) var selectedAgentID = ""
  var selectionVersion = 0

  var snapshot: ChatSnapshot?
  var messages: [Message] = []
  var hasMore = false
  var oldestEntryID = ""
  var loadingOlder = false
  var expanded: Set<String> = []

  var draft = ""
  var attachments: [PendingAttachment] = []
  var replyTo: Message?
  var sending = false
  var draftRequestID = ""
  var failedDraft = ""
  var failedReplyTo = ""
  var failedAttachments: [UUID] = []
  var delivery = BotChatDelivery()
  /// Sent images, keyed by entry and attachment index; they never change once sent.
  private(set) var attachmentImages: [String: UIImage] = [:]

  private var activeRequests = 0
  private(set) var pendingMutations: Set<String> = []
  private(set) var mutationRevision = 0
  var loading = false
  var errorText = ""
  var notice = ""
  var streamStatus = ""
  private(set) var savingConnection = false
  var streamTask: Task<Void, Never>?
  var activityTask: Task<Void, Never>?
  /// Prevents a chat request that was already in flight when the app backgrounded from
  /// reopening its SSE stream after suspension.
  var streamsSuspended = false
  var chatStreamVersion = 0
  var activityVersion = 0

  var agentMemories: [String: [Memory]] = [:]
  var memoryLoadVersion = 0
  var sharedMemories: [Memory] = []
  var sharedSkills: [SharedSkill] = []
  var schedules: [Schedule] = []
  var executions: [Execution] = []
  var activities: [ActivityRecord] = []
  var mcpServers: [MCPServer] = []
  var providers: [ProviderStatus] = []
  var models: [ModelSummary] = []

  var agentDraft: AgentDraft?
  var memoryDraft: MemoryDraft?
  var taskDraft: TaskDraft?
  var mcpDraft: MCPDraft?
  var skillDraft: SkillDraft?
  /// The MCP server whose sign-in sheet is open.
  var signingIn: String?
  var confirmingDelete = false

  var provider = "melious"
  var providerKey = ""

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment, loadKeychain: Bool = true
  ) {
    if loadKeychain {
      if let saved = Keychain.read("server-url"), !saved.isEmpty { serverURL = saved }
      if let saved = Keychain.read("server-token") { token = saved }
    }
    if let url = environment["CRUMBLE_URL"]?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
      serverURL = url.trimmingTrailingSlashes
    }
    if let envToken = environment["CRUMBLE_TOKEN"], !envToken.isEmpty { token = envToken }
    client = APIClient(baseURL: serverURL, token: token)
  }

  init(client: APIClient) {
    self.client = client
  }

  var selectedAgent: Agent? { agents.first { $0.id == selectedAgentID } }

  func botState(_ agent: Agent) -> BotState {
    if !agent.enabled { return .sleeping }
    if agent.id == selectedAgentID, snapshot?.isRunning == true { return .working }
    return .idle
  }

  // MARK: Requests

  func request(
    _ work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
  ) {
    guard let client else {
      errorText = "Connect to your server in Settings."
      return
    }
    let generation = generation
    activeRequests += 1
    loading = true
    errorText = ""
    Task {
      do {
        let apply = try await work(client)
        guard self.generation == generation else { return }
        finishRequest()
        apply?()
      } catch {
        guard self.generation == generation else { return }
        finishRequest()
        errorText = friendlyError(error)
      }
    }
  }

  private func finishRequest() {
    activeRequests = max(0, activeRequests - 1)
    loading = activeRequests > 0
  }

  /// Applies local intent immediately; failed requests restore only the affected record.
  func optimisticMutation(
    key: String,
    update: () -> Void,
    rollback: @escaping @MainActor () -> Void,
    work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
  ) {
    guard let client else {
      errorText = "Connect to your server in Settings."
      return
    }
    guard pendingMutations.insert(key).inserted else { return }
    let generation = generation
    mutationRevision += 1
    update()
    activeRequests += 1
    loading = true
    errorText = ""
    Task {
      do {
        let confirm = try await work(client)
        guard self.generation == generation else { return }
        pendingMutations.remove(key)
        mutationRevision += 1
        finishRequest()
        confirm?()
      } catch {
        guard self.generation == generation else { return }
        pendingMutations.remove(key)
        mutationRevision += 1
        finishRequest()
        rollback()
        errorText = friendlyError(error)
      }
    }
  }

  func showNotice(_ text: String) {
    notice = text
    Task {
      try? await Task.sleep(for: .seconds(2.5))
      if notice == text { notice = "" }
    }
  }

  func clearDeletedSelection() {
    cancelStream()
    selectionVersion += 1
    selectedAgentID = ""
    snapshot = nil
    messages = []
    if case .agent = route {
      if let next = agents.first { selectAgent(next.id) } else { route = nil }
    }
  }
  func updateSelectedAgent(_ id: String) {
    selectedAgentID = id
  }

  func cacheAttachmentImage(_ image: UIImage, key: String) {
    attachmentImages[key] = image
  }
}

extension AppModel {
  // MARK: Settings

  func applyConnection(_ candidate: APIClient) {
    cancelStream()
    generation += 1
    pendingMutations.removeAll()
    mutationRevision += 1
    resetPendingMessages()
    agents = []
    agentMemories = [:]
    sharedMemories = []
    sharedSkills = []
    schedules = []
    executions = []
    mcpServers = []
    providers = []
    models = []
    signingIn = nil
    agentDraft = nil
    memoryDraft = nil
    taskDraft = nil
    mcpDraft = nil
    skillDraft = nil
    snapshot = nil
    messages = []
    client = candidate
    Notifier.shared.connectionChanged()
    activeRequests = 0
    loading = false
    errorText = ""
    selectedAgentID = ""
  }

  func saveSettings() {
    guard !savingConnection else { return }
    let rawURL = serverURL.trimmingCharacters(in: .whitespaces).trimmingTrailingSlashes
    let token = token.trimmingCharacters(in: .whitespaces)
    guard let url = URL(string: rawURL), url.host() != nil,
      ["http", "https"].contains(url.scheme ?? "")
    else {
      errorText = "Enter a valid server URL."
      return
    }
    let candidate = APIClient(baseURL: rawURL, token: token)
    savingConnection = true
    errorText = ""
    Task {
      defer { savingConnection = false }
      do {
        _ = try await candidate.agents()
        try Keychain.write("server-token", value: token)
        try Keychain.write("server-url", value: rawURL)
        applyConnection(candidate)
        showNotice("Connected")
        refresh()
        followActivity()
      } catch {
        errorText = friendlyError(error)
      }
    }
  }

  func saveProviderKey() {
    let provider = provider
    let key = providerKey.trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else {
      errorText = "Enter an API key."
      return
    }
    optimisticMutation(
      key: "provider:\(provider)",
      update: { [self] in
        providerKey = ""
      },
      rollback: { [self] in
        if self.provider == provider, providerKey.isEmpty { providerKey = key }
      },
      work: { client in
        try await client.setProviderKey(provider, apiKey: key)
        return { [self] in
          showNotice("Provider key saved")
          loadProviders()
        }
      })
  }

  func removeProviderKey() {
    let provider = provider
    optimisticMutation(
      key: "provider:\(provider)", update: {}, rollback: {},
      work: { client in
        try await client.deleteProviderKey(provider)
        return { [self] in
          showNotice("Provider key removed")
          loadProviders()
        }
      })
  }
}
