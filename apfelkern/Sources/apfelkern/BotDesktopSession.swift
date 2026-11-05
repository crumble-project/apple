import Foundation
import Observation

/// One bot desktop view's connection: the viewer link, who holds control, and a take or hand-back request that waits
/// for the server.
@MainActor @Observable
public final class BotDesktopSession {
  public enum Action: Equatable, Sendable {
    case take, handBack, waiting
  }

  public let agentID: String
  private let client: APIClient

  public private(set) var link: URL?
  public private(set) var connecting = false
  /// False until the server first reports control; the app can't offer an action before that.
  public private(set) var controlKnown = false
  public private(set) var holder: DesktopControl.Holder = .bot
  public private(set) var changes = 0
  /// The holder asked for and not yet confirmed; control shows the previous holder until then.
  public private(set) var pending: DesktopControl.Holder?
  public private(set) var error = ""

  private var events: Task<Void, Never>?
  private var control: Task<Void, Never>?
  private var left = false

  public init(agentID: String, client: APIClient) {
    self.agentID = agentID
    self.client = client
  }

  nonisolated public static func action(for holder: DesktopControl.Holder, pending: DesktopControl.Holder?) -> Action {
    if pending != nil { return .waiting }
    return holder == .owner ? .handBack : .take
  }

  public var action: Action { controlKnown ? Self.action(for: holder, pending: pending) : .waiting }

  public var controlLabel: String? {
    guard controlKnown else { return nil }
    return holder == .owner ? "You have control" : "The bot has control"
  }

  public func connect() {
    left = false
    reconnect()
    guard events == nil else { return }
    let client = client
    let agentID = agentID
    events = Task { [weak self] in
      var backoff = Duration.milliseconds(500)
      while !Task.isCancelled {
        do {
          try await client.desktopEvents(agentID) { [weak self] state in
            await self?.apply(state)
          }
        } catch {
          if let error = error as? APIError, error.statusCode == 404 { return }
        }
        try? await Task.sleep(for: backoff)
        backoff = min(backoff * 2, .seconds(8))
      }
    }
  }

  /// Viewer links work once, so every (re)load of the viewer needs a new one.
  public func reconnect() {
    guard !connecting else { return }
    connecting = true
    Task {
      do {
        link = try await client.desktopViewer(agentID).url
        error = ""
      } catch {
        self.error = friendlyError(error)
      }
      connecting = false
    }
  }

  public func take() { request(.owner) }

  public func handBack() { request(.bot) }

  /// Control left behind would keep the bot's job paused with nobody watching, so leaving hands it back.
  public func leave() {
    left = true
    events?.cancel()
    events = nil
    if holder == .owner { handBack() }
  }

  /// Returns when no control request is left waiting for the server, for an app that may be suspended after leaving.
  public func settle() async {
    while let control { await control.value }
  }

  private func request(_ wanted: DesktopControl.Holder) {
    guard pending == nil else { return }
    pending = wanted
    error = ""
    control = Task {
      do {
        apply(try await client.setDesktopControl(agentID, holder: wanted))
      } catch {
        self.error = friendlyError(error)
      }
      pending = nil
      control = nil
      // A take the server confirms after the owner left is still control left behind.
      if left, wanted == .owner, holder == .owner { handBack() }
    }
  }

  private func apply(_ state: DesktopControl) {
    // Events and request answers can arrive out of order; the change count orders them.
    guard state.changes >= changes else { return }
    controlKnown = true
    holder = state.holder
    changes = state.changes
  }
}

/// A small live view of a bot desktop. Until asked to wake it, the preview only watches a running desktop: it neither
/// boots the machine nor keeps it awake. Machine state has no live event, so it polls.
@MainActor @Observable
public final class BotDesktopPreview {
  public let agentID: String
  private let client: APIClient
  private let pollInterval: Duration

  public private(set) var running = false
  public private(set) var asked = false
  public private(set) var link: URL?
  public private(set) var connecting = false
  public private(set) var error = ""

  private var polling: Task<Void, Never>?

  public init(agentID: String, client: APIClient, pollInterval: Duration = .seconds(10)) {
    self.agentID = agentID
    self.client = client
    self.pollInterval = pollInterval
  }

  public var live: Bool { asked || running }

  public func start() {
    guard polling == nil else { return }
    let interval = pollInterval
    polling = Task { [weak self] in
      while !Task.isCancelled {
        guard await self?.refresh() != nil else { return }
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// A viewer link works once, so the page it loaded can't come back after this.
  public func stop() {
    polling?.cancel()
    polling = nil
    asked = false
    link = nil
    error = ""
  }

  public func wake() {
    asked = true
    synchronize()
  }

  /// iOS closes the viewer's connection in the background, and its link can't reconnect.
  public func reconnect() {
    guard polling != nil else { return }
    link = nil
    synchronize()
  }

  private func refresh() async {
    guard let running = try? await client.desktopRunning(agentID), polling != nil else { return }
    self.running = running
    synchronize()
  }

  private func synchronize() {
    guard live else {
      link = nil
      error = ""
      return
    }
    guard link == nil, !connecting else { return }
    connecting = true
    let passive = !asked
    Task {
      do {
        let url = try await client.desktopViewer(agentID, passive: passive).url
        if polling != nil, live { link = url }
        error = ""
      } catch {
        self.error = friendlyError(error)
      }
      connecting = false
    }
  }
}
