import Foundation
import UIKit

extension AppModel {
  // MARK: Agents and chat

  func refresh() {
    let revision = mutationRevision
    request { client in
      let agents = try await client.agents()
      return { [self] in
        guard mutationRevision == revision, pendingMutations.isEmpty else { return }
        self.agents = agents
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

  func navigate(to route: Route?) {
    guard let route else { return }
    switch route {
    case .agent(let id):
      if id != selectedAgentID || self.route != route { selectAgent(id) }
    default:
      openPanel(route)
    }
  }

  /// Opens the bot's one continuous chat and follows its event stream.
  func selectAgent(_ id: String) {
    cancelStream()
    selectionVersion += 1
    let version = selectionVersion
    let streamVersion = chatStreamVersion
    updateSelectedAgent(id)
    route = .agent(id)
    snapshot = nil
    messages = pendingMessages[id] ?? []
    hasMore = false
    oldestEntryID = ""
    loadingOlder = false
    replyTo = nil
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
    if !acknowledged.isEmpty {
      pendingMessages[selectedAgentID]?.removeAll { acknowledged.contains($0.requestId ?? "") }
      for requestID in acknowledged {
        pendingSends[selectedAgentID]?[requestID] = nil
        if pendingPreviews[selectedAgentID]?.requestID == requestID {
          pendingPreviews[selectedAgentID] = nil
        }
      }
    }
    // Rebuild from confirmed transcript rows and append local rows so a delayed snapshot
    // cannot erase a message the user has already seen.
    let local = pendingMessages[selectedAgentID] ?? []
    messages = mergeMessages(messages.filter { $0.deliveryState == .confirmed }, incomingMessages)
    messages.append(contentsOf: local)
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
      pendingPreviews[event.agentId] == nil,
      let index = agents.firstIndex(where: { $0.id == event.agentId }) {
      agents[index].lastMessage = lastMessage
    }
    let context = NotificationContext(
      appActive: UIApplication.shared.applicationState == .active, route: route)
    guard let note = notification(for: event, in: context) else { return }
    Notifier.shared.post(event, title: note.title, body: note.body)
  }

  func loadOlder() {
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
