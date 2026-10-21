import Foundation

/// Who operates a bot desktop. While the owner holds control, the bot's desktop job pauses and only the owner's
/// viewer input reaches the bot desktop.
public struct DesktopControl: Codable, Hashable, Sendable {
  public enum Holder: String, Codable, Hashable, Sendable {
    case bot, owner
  }

  public var holder: Holder
  /// How often control changed hands; a desktop job refuses actions it planned before a change.
  public var changes: Int
  public var updatedAt: String

  public init(holder: Holder, changes: Int, updatedAt: String) {
    self.holder = holder
    self.changes = changes
    self.updatedAt = updatedAt
  }

  init(wire: Components.Schemas.DesktopControl) {
    self.init(
      holder: wire.holder == .owner ? .owner : .bot, changes: wire.changes, updatedAt: wire.updatedAt)
  }
}

/// A single-use link to the bot desktop's viewer page. It needs no token, works once, and expires at
/// `expiresAt` unless its connection has started by then.
public struct DesktopViewerLink: Hashable, Sendable {
  public var url: URL
  public var expiresAt: String

  public init(url: URL, expiresAt: String) {
    self.url = url
    self.expiresAt = expiresAt
  }
}

extension APIClient {
  public func desktopControl(_ agentID: String) async throws -> DesktopControl {
    try await invoke {
      DesktopControl(wire: try await $0.getDesktopControl(.init(path: .init(id: agentID))).ok.body.json)
    }
  }

  /// Takes control of the bot desktop (`.owner`) or hands it back (`.bot`).
  public func setDesktopControl(_ agentID: String, holder: DesktopControl.Holder) async throws -> DesktopControl {
    try await invoke {
      DesktopControl(wire: try await $0.putDesktopControl(.init(
        path: .init(id: agentID),
        body: .json(.init(holder: holder == .owner ? .owner : .bot))
      )).ok.body.json)
    }
  }

  /// The bot desktop's control: the current state on connect, then every change.
  public func desktopEvents(_ agentID: String, onEvent: @Sendable (DesktopControl) async -> Void)
    async throws -> Never {
    let body = try await invoke(timeout: serverSentEventsIdleTimeout) {
      try await $0.streamDesktopEvents(.init(path: .init(id: agentID))).ok.body.textEventStream
    }
    try await events(body, parser: SSEParser(accepting: ["control"])) { payload in
      if let state = try? JSONDecoder().decode(Components.Schemas.DesktopControl.self, from: Data(payload.utf8)) {
        await onEvent(DesktopControl(wire: state))
      }
    }
  }

  /// Issues a single-use viewer link for the bot desktop, under the same base URL as the API.
  public func desktopViewer(_ agentID: String) async throws -> DesktopViewerLink {
    let viewer = try await invoke {
      try await $0.createDesktopViewer(.init(path: .init(id: agentID))).created.body.json
    }
    let base = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
    let path = viewer.path.hasPrefix("/") ? String(viewer.path.dropFirst()) : viewer.path
    guard let url = URL(string: path, relativeTo: URL(string: base))?.absoluteURL else {
      throw URLError(.badURL)
    }
    return DesktopViewerLink(url: url, expiresAt: viewer.expiresAt)
  }
}
