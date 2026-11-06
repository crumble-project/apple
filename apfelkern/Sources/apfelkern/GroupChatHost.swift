import Foundation

/// The app model's conversation state. A group chat shares the transcript, composer, and message delivery with bot
/// chats, so this logic runs against the app model instead of owning its state, as `JobBoard` does.
@MainActor
public protocol GroupChatHost: AnyObject, Sendable {
  var client: APIClient? { get }
  var generation: Int { get }
  var mutationRevision: Int { get }
  var pendingMutations: Set<String> { get }
  /// True while streams must stay closed, such as an iOS app in the background.
  var streamsSuspended: Bool { get }

  var route: Route? { get set }
  var selectionVersion: Int { get set }
  var groupChats: [GroupChat] { get set }
  var selectedGroupID: String { get set }
  var groupSnapshot: GroupChatSnapshot? { get set }
  var groupDraft: GroupDraft? { get set }
  var groupStreamTask: Task<Void, Never>? { get set }
  /// What the owner typed in each group they left. Group IDs belong to one server, so a new connection clears it.
  var groupComposerDrafts: [String: String] { get set }
  /// Counts snapshots that brought a new message from someone else, for the rows' arrival animation.
  var groupArrivals: Int { get set }

  var messages: [Message] { get set }
  var hasMore: Bool { get set }
  var oldestEntryID: String { get set }
  var loadingOlder: Bool { get set }
  var draft: String { get set }
  var attachments: [PendingAttachment] { get set }
  var replyTo: Message? { get set }
  var sending: Bool { get set }
  var draftRequestID: String { get set }
  var failedDraft: String { get set }
  var failedReplyTo: String { get set }
  var failedAttachments: [UUID] { get set }
  var delivery: BotChatDelivery { get set }
  var errorText: String { get set }
  var streamStatus: String { get set }

  /// Stops the open bot chat's stream and clears its selection, so a group can take its place.
  func leaveBotChat()
  func request(_ work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?)
  func optimisticMutation(
    key: String,
    update: () -> Void,
    rollback: @escaping @MainActor () -> Void,
    work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
  )
  func showNotice(_ text: String)
}

extension GroupChatHost {
  public var streamsSuspended: Bool { false }

  /// Loads the group list quietly: a failed load leaves the list as it is.
  public func loadGroupChats() {
    guard let client else { return }
    let generation = generation
    let revision = mutationRevision
    Task {
      guard let groups = try? await client.groupChats(), self.generation == generation,
        mutationRevision == revision, pendingMutations.isEmpty
      else { return }
      groupChats = groups
      if !selectedGroupID.isEmpty, !groups.contains(where: { $0.id == selectedGroupID }) {
        leaveGroup()
        route = nil
      }
    }
  }

  /// Opens a group chat and follows its event stream.
  public func selectGroup(_ id: String) {
    keepGroupDraft()
    leaveBotChat()
    stopGroupStream()
    selectionVersion += 1
    let version = selectionVersion
    selectedGroupID = id
    route = .group(id)
    groupSnapshot = nil
    messages = delivery.messages(botID: GroupChat.deliveryKey(id))
    hasMore = false
    oldestEntryID = ""
    loadingOlder = false
    replyTo = nil
    draft = groupComposerDrafts[id] ?? ""
    attachments = []
    failedDraft = ""
    failedReplyTo = ""
    failedAttachments = []
    sending = false
    draftRequestID = ""
    loadGroup(id, version: version)
  }

  private func loadGroup(_ id: String, version: Int) {
    request { client in
      let snapshot = try await client.groupChat(id)
      return { [self] in
        guard selectionVersion == version, selectedGroupID == id else { return }
        applyGroupSnapshot(snapshot)
        hasMore = snapshot.hasMore
        oldestEntryID = snapshot.oldestEntryId ?? ""
        if !streamsSuspended {
          groupStreamTask = Task { await streamGroup(client: client, id: id, version: version) }
        }
      }
    }
  }

  /// Closes the open group chat, if any, so a bot chat or panel can take its place.
  public func leaveGroup() {
    keepGroupDraft()
    stopGroupStream()
    selectedGroupID = ""
    groupSnapshot = nil
  }

  private func keepGroupDraft() {
    guard !selectedGroupID.isEmpty else { return }
    groupComposerDrafts[selectedGroupID] = draft.nilIfEmpty
  }

  public func stopGroupStream() {
    groupStreamTask?.cancel()
    groupStreamTask = nil
    streamStatus = ""
  }

  /// Keeps older pages the owner already loaded; snapshots only carry the newest page.
  public func applyGroupSnapshot(_ incoming: GroupChatSnapshot) {
    let key = GroupChat.deliveryKey(selectedGroupID)
    delivery.acknowledge(botID: key, requestIDs: Set(incoming.messages.compactMap(\.requestId)))
    let known = Set(messages.map(\.id))
    messages = mergeMessages(messages.filter { $0.deliveryState == .confirmed }, incoming.messages)
    messages.append(contentsOf: delivery.messages(botID: key))
    // The first snapshot is history, and the owner's own message is already on screen.
    if groupSnapshot != nil,
      messages.contains(where: { !known.contains($0.id) && !($0.role == "user" && $0.requestId != nil) }) {
      groupArrivals += 1
    }
    if let index = groupChats.firstIndex(where: { $0.id == incoming.groupChat.id }),
      !pendingMutations.contains("group:\(incoming.groupChat.id)") {
      groupChats[index] = incoming.groupChat
    }
    var snapshot = incoming
    snapshot.messages = []
    groupSnapshot = snapshot
  }

  private func streamGroup(client: APIClient, id: String, version: Int) async {
    var backoff = Duration.milliseconds(500)
    while !Task.isCancelled, !streamsSuspended {
      do {
        try await client.groupChatEvents(id) { payload in
          guard
            let snapshot = try? JSONDecoder().decode(GroupChatSnapshot.self, from: Data(payload.utf8))
          else { return }
          await MainActor.run {
            guard self.selectionVersion == version, self.selectedGroupID == id, !Task.isCancelled
            else { return }
            self.applyGroupSnapshot(snapshot)
            self.streamStatus = ""
          }
        }
      } catch {
        if Task.isCancelled || selectionVersion != version { return }
        if let apiError = error as? APIError, apiError.statusCode == 401 {
          errorText = friendlyError(error)
          streamStatus = "Disconnected"
          return
        }
        if let apiError = error as? APIError, apiError.statusCode == 404 {
          leaveGroup()
          route = nil
          loadGroupChats()
          return
        }
        streamStatus = "Reconnecting…"
      }
      try? await Task.sleep(for: backoff)
      backoff = min(backoff * 2, .seconds(8))
    }
  }

  /// Follows the open group on a new connection, such as after sleep or the background; the first snapshot catches up.
  public func reconnectGroupStream() {
    guard let client, !selectedGroupID.isEmpty else { return }
    groupStreamTask?.cancel()
    let id = selectedGroupID
    let version = selectionVersion
    // The stream only starts after a first snapshot, so a failed load has nothing to reconnect.
    guard groupSnapshot != nil else {
      loadGroup(id, version: version)
      return
    }
    groupStreamTask = Task { await streamGroup(client: client, id: id, version: version) }
  }

  @discardableResult
  public func sendGroupMessage() -> Task<Void, Never>? {
    guard groupSnapshot != nil, let client else { return nil }
    let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let files = attachments
    guard !content.isEmpty || !files.isEmpty else { return nil }
    let id = selectedGroupID
    let key = GroupChat.deliveryKey(id)
    let reply = replyTo?.entryId ?? ""
    draftRequestID = newRequestID()
    let requestID = draftRequestID
    let record = BotChatDelivery.Send(
      content: content, replyTo: reply, attachments: files, replyPreview: replyTo?.text.nilIfEmpty)
    failedDraft = content
    sending = true
    draft = ""
    attachments = []
    messages.append(delivery.stage(record, botID: key, requestID: requestID))
    replyTo = nil
    let generation = generation
    let version = selectionVersion
    return Task {
      do {
        try await client.sendGroupMessage(
          id, content: content, requestID: requestID, replyTo: reply, attachments: files.map(\.outgoing))
        guard self.generation == generation else { return }
        delivery.accepted(botID: key, requestID: requestID)
        guard selectionVersion == version, selectedGroupID == id else { return }
        sending = false
        draftRequestID = ""
        failedDraft = ""
      } catch {
        guard self.generation == generation else { return }
        guard failGroupMessage(error, id: id, requestID: requestID, version: version) else { return }
        if selectionVersion == version, selectedGroupID == id, draft.isEmpty, attachments.isEmpty {
          draft = content
          attachments = files
        }
      }
    }
  }

  /// Re-sends a failed group message with its original idempotency key and attachments.
  public func retryGroupMessage(_ message: Message) {
    let id = selectedGroupID
    let key = GroupChat.deliveryKey(id)
    guard message.deliveryState == .failed, let requestID = message.requestId, let client,
      let record = delivery.beginRetry(botID: key, requestID: requestID)
    else { return }
    if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
      messages[visible].deliveryState = .sending
    }
    if draft == record.content && attachments.map(\.id) == record.attachments.map(\.id) {
      draft = ""
      attachments = []
    }
    sending = true
    let generation = generation
    let version = selectionVersion
    Task {
      do {
        try await client.sendGroupMessage(
          id, content: record.content, requestID: requestID, replyTo: record.replyTo,
          attachments: record.attachments.map(\.outgoing))
        guard self.generation == generation else { return }
        delivery.accepted(botID: key, requestID: requestID)
        if selectionVersion == version, selectedGroupID == id { sending = false }
      } catch {
        guard self.generation == generation else { return }
        _ = failGroupMessage(error, id: id, requestID: requestID, version: version)
      }
    }
  }

  private func failGroupMessage(_ error: Error, id: String, requestID: String, version: Int) -> Bool {
    let current = selectionVersion == version && selectedGroupID == id
    if current { sending = false }
    guard delivery.fail(botID: GroupChat.deliveryKey(id), requestID: requestID) else { return false }
    if current {
      errorText = "Message was not confirmed: " + friendlyError(error)
      if let visible = messages.firstIndex(where: { $0.requestId == requestID }) {
        messages[visible].deliveryState = .failed
      }
    }
    return true
  }

  /// Ends every running bot turn in the open group; the stream reports when they have stopped.
  public func stopGroup() {
    let id = selectedGroupID
    optimisticMutation(
      key: "stop:\(id)",
      update: { [self] in showNotice("Stopping…") }, rollback: {},
      work: { client in
        try await client.stopGroupChat(id)
        return nil
      })
  }

  public func loadOlderGroupMessages() {
    guard !loadingOlder, hasMore, !oldestEntryID.isEmpty else { return }
    let id = selectedGroupID
    let before = oldestEntryID
    let version = selectionVersion
    loadingOlder = true
    request { client in
      do {
        let page = try await client.groupChatHistory(id, before: before, limit: 100)
        return { [self] in
          guard selectionVersion == version, selectedGroupID == id else { return }
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

  /// A tapped group notification opens its group, looking it up again if the list is stale.
  public func openNotificationGroup(_ id: String) {
    guard !groupChats.contains(where: { $0.id == id }) else {
      selectGroup(id)
      return
    }
    request { client in
      let groups = try await client.groupChats()
      return { [self] in
        guard groups.contains(where: { $0.id == id }) else {
          errorText = "The group chat for this notification no longer exists."
          return
        }
        if pendingMutations.isEmpty { groupChats = groups }
        selectGroup(id)
      }
    }
  }
}
