import Foundation
import Observation

/// Orders a board's reads: one that predates a newer read or a write is ignored.
struct ReadOrder {
  private var started = 0
  private var settled = 0

  mutating func begin() -> Int {
    started += 1
    return started
  }

  mutating func accept(_ read: Int) -> Bool {
    guard read > settled else { return false }
    settled = read
    return true
  }

  mutating func settle() { settled = started }
}

/// What the account connected that bots' settings read: password managers and event sources.
@MainActor
public final class ConnectedServices {
  public let passwordManagers = PasswordManagerBoard()
  public let eventSources = EventSourceBoard()

  public init() {}

  public func reset() {
    passwordManagers.reset()
    eventSources.reset()
  }
}

/// The password managers the account connected, which a secret can read from. Results that return
/// after the connection changed are dropped.
@MainActor @Observable
public final class PasswordManagerBoard {
  private var loaded: [PasswordManager] = []
  private var isLoaded = false
  private var order = ReadOrder()
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    loaded = []
    isLoaded = false
    order = ReadOrder()
  }

  /// What a secret can read from. `known` stands in until this board has read the server.
  public func connected(knownUntilLoaded known: [PasswordManager]) -> [PasswordManager] {
    isLoaded ? loaded.filter(\.connected) : known
  }

  public func refresh(client: APIClient) {
    let version = scope
    let read = order.begin()
    Task {
      guard let managers = try? await client.passwordManagers(), scope == version, order.accept(read) else { return }
      loaded = managers
      isLoaded = true
    }
  }
}
