import Foundation
import Observation

/// The account's pinned conversations. A change shows at once and comes back on failure. Writes run
/// one at a time and only the newest change waits, so the server ends on what the owner did last.
/// Another app's change arrives as a `pins` event and replaces the pins unless a write is waiting.
///
/// Nothing can change until the account's pins are read: a change is written whole, so writing
/// before then would replace pins this device hasn't seen. A server too old to keep pins never
/// reports any, so its pins stay unavailable.
@MainActor @Observable
public final class PinBoard {
  public private(set) var pins = PinnedConversations()
  /// Whether the account's pins have been read, so a change may be written.
  public private(set) var isLoaded = false
  /// What a failed write comes back to.
  private var confirmed = PinnedConversations()
  private var wanted: PinnedConversations?
  private(set) var isWriting = false
  private var order = ReadOrder()
  private var scope = 0

  public init() {}

  /// A new connection may be another account, so its pins start unread.
  public func reset() {
    scope += 1
    pins = PinnedConversations()
    confirmed = pins
    wanted = nil
    isWriting = false
    isLoaded = false
    order = ReadOrder()
  }

  /// A failed read keeps what's on screen; the next connection or event reads again.
  public func refresh(client: APIClient) {
    let version = scope
    let attempt = order.begin()
    Task {
      let keys = try? await client.accountPins()
      guard scope == version, order.accept(attempt), let keys else { return }
      adopt(keys)
    }
  }

  /// Another app changed the pins. A waiting write is newer than what it saw, so it wins.
  public func receive(_ keys: [String]) {
    order.settle()
    adopt(keys)
  }

  public func change(
    _ next: PinnedConversations, client: APIClient,
    session: URLSession = URLSession(configuration: .ephemeral),
    onFailure: @escaping @MainActor (String) -> Void
  ) {
    guard isLoaded, next != pins else { return }
    pins = next
    wanted = next
    if !isWriting { write(next, client: client, session: session, onFailure: onFailure) }
  }

  private func adopt(_ keys: [String]) {
    guard wanted == nil, !isWriting else { return }
    confirmed = PinnedConversations(keys: keys)
    pins = confirmed
    isLoaded = true
  }

  private func write(
    _ next: PinnedConversations, client: APIClient, session: URLSession,
    onFailure: @escaping @MainActor (String) -> Void
  ) {
    isWriting = true
    let version = scope
    Task {
      var failure: String?
      do {
        try await client.setAccountPins(next.keys, session: session)
      } catch {
        failure = friendlyError(error)
      }
      guard scope == version else { return }
      if failure == nil { confirmed = next }
      order.settle()
      isWriting = false
      if let wanted, wanted != next {
        write(wanted, client: client, session: session, onFailure: onFailure)
        return
      }
      wanted = nil
      if let failure {
        pins = confirmed
        onFailure(failure)
      }
    }
  }
}
