import CoreGraphics
import Foundation

/// Tells the server which chat this app's view shows, so a reply there sends no push to any of the owner's
/// devices, and which replies the owner has seen. Independent of push registration and notification permission.
///
/// A view reports a chat only while the app is active, the route shows that chat, and the chat's view is mounted.
/// Reports for the view go out one at a time and always send the latest state, so a delayed refresh can't follow
/// a clear. A new connection gets a new view ID; the old view clears through the old connection.
@MainActor
public final class ChatAttention {
  public struct Timing: Sendable {
    public var heartbeat: Duration
    /// How long displayed replies gather before they're sent together.
    public var batchDelay: Duration
    public var retry: Duration
    public var maxRetry: Duration
    /// How long a retired view gets to clear before its requests are cancelled.
    public var clearTimeout: Duration

    public init(
      heartbeat: Duration = .seconds(30), batchDelay: Duration = .milliseconds(100),
      retry: Duration = .seconds(1), maxRetry: Duration = .seconds(30), clearTimeout: Duration = .seconds(2)
    ) {
      self.heartbeat = heartbeat
      self.batchDelay = batchDelay
      self.retry = retry
      self.maxRetry = maxRetry
      self.clearTimeout = clearTimeout
    }
  }

  /// The server's name for this view; a new connection gets a new one.
  public private(set) var viewID = newRequestID()
  private let timing: Timing
  private var connection: Connection?
  /// A connection signed out through `disconnect`, refused until a different one arrives.
  private var disconnected: ConnectionKey?
  private var active = false
  private var route: ChatAttentionChat?
  private var mounted: ChatAttentionChat?
  private var surfaces = ReplySurfaces()

  public init(timing: Timing = Timing()) {
    self.timing = timing
  }

  /// The chat that has the owner's attention, if any.
  public var shown: ChatAttentionChat? {
    guard active, let route, route == mounted else { return nil }
    return route
  }

  /// The signed-in connection, whether the app or window is active, and the chat its route shows.
  public func update(client: APIClient?, active: Bool, route: ChatAttentionChat?) {
    let key = client.flatMap(ConnectionKey.init)
    let next = key == disconnected ? nil : key
    if connection?.key != next {
      if next != nil { disconnected = nil }
      replaceConnection(with: next.flatMap { key in client.map { ($0, key) } })
    }
    self.active = active
    self.route = route
    refresh()
  }

  // MARK: The chat's view

  /// The chat's view is on screen and showing its transcript.
  public func mount(_ chat: ChatAttentionChat) {
    if mounted != chat { surfaces.keep(only: chat) }
    mounted = chat
    refresh()
  }

  /// A view that goes away clears only its own chat, since the next one can mount first. Its rows take their
  /// surfaces with them.
  public func unmount(_ chat: ChatAttentionChat) {
    guard mounted == chat else { return }
    mounted = nil
    refresh()
  }

  /// What the toolbar and composer cover at the top and bottom of the chat's scroll view.
  public func setViewportInsets(top: CGFloat, bottom: CGFloat) {
    surfaces.setInsets(top: top, bottom: bottom)
    acknowledgeVisible()
  }

  /// A reply surface's frame and its scroll view's size, both in the scroll view's coordinates, the events it
  /// shows, and whether its content is ready.
  public func setSurface(
    _ key: String, of chat: ChatAttentionChat, frame: CGRect, container: CGSize, eventIDs: [String], ready: Bool
  ) {
    surfaces.set(key, of: chat, frame: frame, container: container, eventIDs: eventIDs, ready: ready)
    acknowledgeVisible()
  }

  public func removeSurface(_ key: String, of chat: ChatAttentionChat) {
    surfaces.remove(key, of: chat)
  }

  // MARK: Connections

  /// Clears this view through `client` before its session is revoked, waiting at most the clear timeout. Seen
  /// replies not yet sent are dropped; a lost clear expires on the server.
  public func disconnect(_ client: APIClient) async {
    guard let old = connection, old.key == ConnectionKey(client) else { return }
    disconnected = old.key
    replaceConnection(with: nil)
    active = false
    route = nil
    await old.reporter.finished()
  }

  /// Waits, at most the clear timeout, for this view's latest report to reach the server, as when iOS suspends the
  /// app after it leaves the foreground.
  public func settle() async {
    await connection?.reporter.idle(within: timing.clearTimeout)
  }

  private func replaceConnection(with next: (client: APIClient, key: ConnectionKey)?) {
    if let old = connection {
      old.stop()
      old.reporter.retire(within: timing.clearTimeout)
    }
    viewID = newRequestID()
    surfaces.keep(only: nil)
    connection = next.map { Connection(client: $0.client, key: $0.key, viewID: viewID, timing: timing) }
  }

  private func refresh() {
    connection?.reporter.set(shown)
    acknowledgeVisible()
  }

  private func acknowledgeVisible() {
    guard let chat = shown, let connection else { return }
    connection.displayed(surfaces.visibleEventIDs(in: chat), in: chat)
  }
}

/// One signed-in session: a server and its token. Signed out when the token is empty.
struct ConnectionKey: Hashable {
  var baseURL: String
  var token: String

  init?(_ client: APIClient) {
    guard !client.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    baseURL = client.baseURL
    token = client.token
  }
}

/// A connection's view reporter and its seen replies, which wait in per-chat batches and retry until they're
/// accepted, the server refuses them, or the connection ends.
@MainActor
private final class Connection {
  let key: ConnectionKey
  let client: APIClient
  let reporter: ViewReporter
  private let timing: ChatAttention.Timing
  /// Every event queued so far, so a surface that stays on screen is acknowledged once.
  private var known: [ChatAttentionChat: Set<String>] = [:]
  private var pending: [(chat: ChatAttentionChat, eventIDs: [String])] = []
  private var worker: Task<Void, Never>?
  private var stopped = false
  private var unauthorized = false

  init(client: APIClient, key: ConnectionKey, viewID: String, timing: ChatAttention.Timing) {
    self.client = client
    self.key = key
    self.timing = timing
    reporter = ViewReporter(client: client, viewID: viewID, timing: timing)
  }

  func stop() {
    stopped = true
    worker?.cancel()
    worker = nil
    pending = []
    known = [:]
  }

  func displayed(_ eventIDs: [String], in chat: ChatAttentionChat) {
    guard !stopped, !unauthorized else { return }
    var known = self.known[chat, default: []]
    let earned = eventIDs.filter { !$0.isEmpty && known.insert($0).inserted }
    self.known[chat] = known
    guard !earned.isEmpty else { return }
    if let index = pending.firstIndex(where: { $0.chat == chat }) {
      pending[index].eventIDs += earned
    } else {
      pending.append((chat, earned))
    }
    guard worker == nil else { return }
    worker = Task { [weak self] in await self?.flush() }
  }

  /// A batch keeps the chat it was earned in, wherever the owner has gone since.
  private func flush() async {
    try? await Task.sleep(for: timing.batchDelay)
    while !stopped, !unauthorized, !Task.isCancelled, let next = pending.first {
      let batch = Array(next.eventIDs.prefix(100))
      pending[0].eventIDs.removeFirst(batch.count)
      if pending[0].eventIDs.isEmpty { pending.removeFirst() }
      await submit(batch, in: next.chat)
    }
    if !Task.isCancelled { worker = nil }
  }

  /// The server accepts a batch whole or not at all, so a refused batch is sent again one event at a time and only
  /// the refused events are dropped.
  private func submit(_ eventIDs: [String], in chat: ChatAttentionChat) async {
    var delay = timing.retry
    while !stopped, !unauthorized, !Task.isCancelled {
      do {
        try await client.markRepliesSeen(eventIDs, in: chat)
        return
      } catch let error as APIError where error.statusCode == 401 {
        unauthorized = true
      } catch let error as APIError where [400, 404].contains(error.statusCode) {
        guard eventIDs.count > 1 else { return }
        for id in eventIDs { await submit([id], in: chat) }
        return
      } catch {
        try? await Task.sleep(for: delay)
        delay = min(delay * 2, timing.maxRetry)
      }
    }
  }
}

/// Sends one view's reports in order. Each request carries the newest state, so changes that pile up behind a
/// request in flight collapse into one, and a refresh can't follow a clear.
@MainActor
private final class ViewReporter {
  private let client: APIClient
  private let viewID: String
  private let timing: ChatAttention.Timing
  private var desired: ChatAttentionChat?
  private var revision = 0
  private var sent = 0
  private var worker: Task<Void, Never>?
  private var backoff: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var retired = false
  private var stopped = false

  init(client: APIClient, viewID: String, timing: ChatAttention.Timing) {
    self.client = client
    self.viewID = viewID
    self.timing = timing
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: timing.heartbeat)
        guard let self, !Task.isCancelled else { return }
        if !retired, let desired { set(desired, force: true) }
      }
    }
  }

  func set(_ chat: ChatAttentionChat?, force: Bool = false) {
    guard !stopped, force || chat != desired else { return }
    desired = chat
    revision += 1
    backoff?.cancel()
    // Holds the reporter until it's done, so a retired view still sends its clear.
    if worker == nil { worker = Task { await self.run() } }
  }

  /// Clears what this view reported, if anything, then cancels whatever is left after `timeout`.
  func retire(within timeout: Duration) {
    retired = true
    heartbeat?.cancel()
    set(nil)
    guard worker != nil else { return }
    Task { [weak self] in
      try? await Task.sleep(for: timeout)
      self?.cancel()
    }
  }

  func finished() async {
    await worker?.value
  }

  func idle(within timeout: Duration) async {
    let deadline = ContinuousClock.now + timeout
    while worker != nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  private func cancel() {
    stopped = true
    heartbeat?.cancel()
    backoff?.cancel()
    worker?.cancel()
  }

  private func run() async {
    var delay = timing.retry
    while !stopped, !Task.isCancelled, sent != revision {
      let version = revision
      do {
        try await client.reportChatAttention(view: viewID, chat: desired)
        sent = version
        delay = timing.retry
      } catch let error as APIError where error.statusCode == 401 {
        stopped = true
      } catch let error as APIError where [400, 404].contains(error.statusCode) {
        // The chat is gone or the server refuses it; only a new state is worth sending.
        sent = version
      } catch {
        guard !Task.isCancelled, version == revision else { continue }
        let wait = Task { [delay] in _ = try? await Task.sleep(for: delay) }
        backoff = wait
        await wait.value
        backoff = nil
        delay = min(delay * 2, timing.maxRetry)
      }
    }
    worker = nil
  }
}
