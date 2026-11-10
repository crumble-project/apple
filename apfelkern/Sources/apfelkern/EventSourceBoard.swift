import Foundation
import Observation

/// One webhook address on the event relay, which automations can start from.
public struct EventSource: Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// The account's event sources. Results that return after the connection changed are dropped.
@MainActor @Observable
public final class EventSourceBoard {
  public private(set) var sources: [EventSource] = []
  public private(set) var isLoaded = false
  private var order = ReadOrder()
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    sources = []
    isLoaded = false
    order = ReadOrder()
  }

  public func refresh(client: APIClient) {
    let version = scope
    let read = order.begin()
    Task {
      guard let loaded = try? await client.eventSources(), scope == version, order.accept(read) else { return }
      sources = loaded
      isLoaded = true
    }
  }
}
