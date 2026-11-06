import apfelkern
import Foundation
import UIKit
import UserNotifications

extension AppModel {
  // MARK: Agents and chat

  func refresh() {
    let revision = mutationRevision
    request { client in
      let agents = try await client.agents()
      return { [self] in
        guard mutationRevision == revision, pendingMutations.isEmpty else { return }
        self.agents = agents
        loadCapabilities()
        loadAccount()
        loadGroupChats()
        loadConversationSummaries()
        // An open group chat stays open; the bot list only refreshes.
        guard selectedGroupID.isEmpty else {
          Notifier.shared.routePendingTap()
          return
        }
        // A phone opens on the conversation list, so only a chat already open reloads.
        if UIDevice.current.userInterfaceIdiom == .phone, !agents.isEmpty, !isBotChatOpen {
          Notifier.shared.routePendingTap()
          return
        }
        var chosen = selectedAgentID
        if !agents.contains(where: { $0.id == chosen }) { chosen = agents.first?.id ?? "" }
        if chosen.isEmpty {
          cancelStream()
          updateSelectedAgent("")
          snapshot = nil
          messages = []
        } else {
          selectAgent(chosen)
          Notifier.shared.routePendingTap()
        }
      }
    }
  }

  /// Reloads the bot list when a bot may have appeared, leaving the open chat alone.
  func reconcileAgents() {
    guard let client else { return }
    let generation = generation
    let revision = mutationRevision
    Task {
      guard let agents = try? await client.agents(), self.generation == generation,
        mutationRevision == revision, pendingMutations.isEmpty else { return }
      self.agents = agents
    }
  }

  var isBotChatOpen: Bool {
    if case .agent = route { true } else { false }
  }

  func navigate(to route: Route?) {
    guard let route else { return }
    switch route {
    case .agent(let id):
      // Back in the chat it just left, the stream is still following it.
      if id == selectedAgentID, selectedGroupID.isEmpty, snapshot != nil {
        self.route = route
      } else {
        selectAgent(id)
      }
    case .group(let id):
      if id == selectedGroupID, groupSnapshot != nil { self.route = route } else { selectGroup(id) }
    default:
      openPanel(route)
    }
  }

  /// Opens the bot's one continuous chat and follows its event stream.
  func selectAgent(_ id: String) {
    leaveGroup()
    cancelStream()
    selectionVersion += 1
    let version = selectionVersion
    let streamVersion = chatStreamVersion
    updateSelectedAgent(id)
    route = .agent(id)
    snapshot = nil
    messages = delivery.messages(botID: id)
    hasMore = false
    oldestEntryID = ""
    loadingOlder = false
    replyTo = nil
    jobBoard.select(id)
    heldActionBoard.select(id)
    botRequestBoard.select(id)
    botSecretBoard.select(id)
    draft = ""
    attachments = []
    failedDraft = ""
    failedReplyTo = ""
    failedAttachments = []
    sending = false
    draftRequestID = ""
    request { client in
      let snapshot = try await client.chat(id)
      return { [self] in
        guard selectionVersion == version, selectedAgentID == id, chatStreamVersion == streamVersion
        else { return }
        applySnapshot(snapshot)
        hasMore = snapshot.hasMore ?? false
        oldestEntryID = snapshot.oldestEntryId ?? ""
        if !streamsSuspended, chatStreamVersion == streamVersion {
          streamTask = Task { await streamChat(client: client, id: id, version: version) }
        }
      }
    }
  }

  /// Keeps older pages the owner already loaded; snapshots only carry the newest page.
  func applySnapshot(_ incoming: ChatSnapshot) {
    let incomingMessages = incoming.messages ?? []
    let acknowledged = Set(incomingMessages.compactMap(\.requestId))
    delivery.acknowledge(botID: selectedAgentID, requestIDs: acknowledged)
    // Rebuild from confirmed transcript rows and append local rows so a delayed snapshot
    // cannot erase a message the user has already seen.
    let local = delivery.messages(botID: selectedAgentID)
    messages = mergeMessages(messages.filter { $0.deliveryState == .confirmed }, incomingMessages)
    messages.append(contentsOf: local)
    refreshJobsIfChanged()
    refreshHeldActionsIfChanged()
    refreshBotRequestsIfChanged()
    refreshBotSecretsIfChanged()
    var snapshot = incoming
    snapshot.messages = nil
    self.snapshot = snapshot
  }

  func cancelStream() {
    chatStreamVersion += 1
    streamTask?.cancel()
    streamTask = nil
    streamStatus = ""
  }

  /// Stops long-lived sockets while the app is backgrounded. Draft text, attachments, and
  /// navigation stay in memory so returning to the app does not discard the user's work.
  func suspendStreams() {
    streamsSuspended = true
    cancelStream()
    stopGroupStream()
    activityVersion += 1
    activityTask?.cancel()
    activityTask = nil
  }

  /// Rehydrates the current chat after a background suspension, then resumes both SSE streams
  /// without routing through `selectAgent` (which intentionally clears composer state).
  func resumeStreams() {
    streamsSuspended = false
    // Be safe when scene phase notifications arrive more than once.
    cancelStream()
    followActivity()
    loadGroupChats()
    reconnectGroupStream()
    guard client != nil, !selectedAgentID.isEmpty else {
      if agents.isEmpty, route == nil { refresh() }
      return
    }
    let id = selectedAgentID
    let version = selectionVersion
    let streamVersion = chatStreamVersion
    request { client in
      let snapshot = try await client.chat(id)
      return { [self] in
        guard !streamsSuspended, chatStreamVersion == streamVersion, selectionVersion == version,
          selectedAgentID == id
        else { return }
        applySnapshot(snapshot)
        hasMore = snapshot.hasMore ?? false
        oldestEntryID = snapshot.oldestEntryId ?? ""
        if !streamsSuspended, chatStreamVersion == streamVersion {
          streamTask = Task { await streamChat(client: client, id: id, version: version) }
        }
      }
    }
  }

  private func streamChat(client: APIClient, id: String, version: Int) async {
    var backoff = Duration.milliseconds(500)
    while !Task.isCancelled, !streamsSuspended {
      do {
        try await client.chatEvents(id) { payload in
          guard
            let snapshot = try? JSONDecoder().decode(ChatSnapshot.self, from: Data(payload.utf8))
          else { return }
          await MainActor.run {
            guard self.selectionVersion == version, !Task.isCancelled else { return }
            self.applySnapshot(snapshot)
            self.streamStatus = ""
            self.errorText = ""
          }
        }
      } catch {
        if Task.isCancelled || selectionVersion != version { return }
        if let apiError = error as? APIError, apiError.statusCode == 401 {
          errorText = friendlyError(error)
          streamStatus = "Disconnected"
          return
        }
        streamStatus = "Reconnecting…"
      }
      try? await Task.sleep(for: backoff)
      backoff = min(backoff * 2, .seconds(8))
    }
  }

  /// Follows server-wide activity for notifications, reconnecting as the chat stream does.
  func followActivity() {
    activityVersion += 1
    let version = activityVersion
    activityTask?.cancel()
    guard let client else { return }
    let generation = generation
    activityTask = Task {
      var backoff = Duration.milliseconds(500)
      while !Task.isCancelled, !self.streamsSuspended, self.generation == generation {
        do {
          try await client.activityEvents { payload in
            guard
              let event = try? JSONDecoder().decode(ActivityEvent.self, from: Data(payload.utf8))
            else { return }
            await MainActor.run {
              guard self.generation == generation, self.activityVersion == version,
                !self.streamsSuspended
              else { return }
              self.handleActivity(event)
            }
          }
        } catch {
          if let apiError = error as? APIError, apiError.statusCode == 401 { return }
        }
        try? await Task.sleep(for: backoff)
        backoff = min(backoff * 2, .seconds(8))
      }
    }
  }

  func handleActivity(_ event: ActivityEvent) {
    if event.type == "chat-preview", let lastMessage = event.lastMessage,
      delivery.preview(botID: event.agentId) == nil,
      let index = agents.firstIndex(where: { $0.id == event.agentId }) {
      // Every reconnection replays the previews, so only a changed one means the chat moved.
      if agents[index].lastMessage != lastMessage { noteConversationMoved(.agent(event.agentId), preview: lastMessage) }
      agents[index].lastMessage = lastMessage
    }
    if event.type == "reply", let group = event.groupId { noteConversationMoved(.group(group), preview: event.preview) }
    let context = NotificationContext(
      appActive: UIApplication.shared.applicationState == .active, route: route)
    guard let note = notification(for: event, in: context) else { return }
    unread.add(event)
    Notifier.shared.post(event, title: note.title, body: note.body)
  }

  /// The chat on screen counts as read, as the web marks it when its tab shows it.
  func markChatSeen() {
    if UIApplication.shared.applicationState == .active { unread.markSeen(route) }
  }

  /// A badge outlives the app, so launch clears what the last run left.
  func showUnreadBadge() {
    UNUserNotificationCenter.current().setBadgeCount(unread.total) { _ in }
  }

  func loadOlder() {
    guard selectedGroupID.isEmpty else { return loadOlderGroupMessages() }
    guard !loadingOlder, hasMore, !oldestEntryID.isEmpty else { return }
    let id = selectedAgentID
    let before = oldestEntryID
    let version = selectionVersion
    loadingOlder = true
    request { client in
      do {
        let page = try await client.chatHistory(id, before: before, limit: 100)
        return { [self] in
          guard selectionVersion == version else { return }
          loadingOlder = false
          messages = mergeMessages(messages, page.messages ?? [])
          refreshHeldActionsIfChanged()
          refreshBotRequestsIfChanged()
          refreshBotSecretsIfChanged()
          hasMore = page.hasMore ?? false
          oldestEntryID = page.oldestEntryId ?? ""
        }
      } catch {
        if self.selectionVersion == version { self.loadingOlder = false }
        throw error
      }
    }
  }
}
