import Foundation
import Observation

/// The account's skill and memory changes, newest first. A revert's outcome is the server's, so it
/// shows a pending state and its row appears once confirmed. Results that return after the list or
/// the connection changed are dropped.
@MainActor @Observable
public final class ChangeBoard {
  public private(set) var changes: [LearnedChange] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  public private(set) var hasMore = false
  public private(set) var isLoadingMore = false
  /// The one bot the list shows, or nil for every change.
  public private(set) var botID: String?
  /// Why reverting failed, by change.
  public private(set) var errors: [String: String] = [:]
  private var reverting: Set<String> = []
  private var listVersion = 0
  private var scope = 0
  private let pageSize: Int
  /// The server's limit on one read.
  private static let largestRead = 200

  public init(pageSize: Int = 50) {
    self.pageSize = pageSize
  }

  public func reset() {
    scope += 1
    listVersion += 1
    changes = []
    isLoaded = false
    readError = nil
    hasMore = false
    isLoadingMore = false
    botID = nil
    errors = [:]
    reverting = []
  }

  public func isReverting(_ change: LearnedChange) -> Bool { reverting.contains(change.id) }

  public func show(botID: String?, client: APIClient) {
    guard botID != self.botID else { return }
    self.botID = botID
    changes = []
    isLoaded = false
    hasMore = false
    readError = nil
    refresh(client: client)
  }

  /// Back to the newest page, as the web does on refresh.
  public func refresh(client: APIClient) {
    read(limit: pageSize, client: client)
  }

  private func read(limit: Int, client: APIClient) {
    let version = newList()
    let bot = botID
    Task {
      do {
        let page = try await client.changes(agentID: bot, limit: limit)
        guard listVersion == version else { return }
        changes = page
        hasMore = page.count == limit
        isLoaded = true
        readError = nil
      } catch {
        guard listVersion == version else { return }
        readFailed(error, bot: bot, client: client)
      }
    }
  }

  public func loadMore(client: APIClient) {
    guard hasMore, !isLoadingMore, let last = changes.last else { return }
    let version = listVersion
    let bot = botID
    isLoadingMore = true
    readError = nil
    Task {
      do {
        let page = try await client.changes(agentID: bot, before: last.id, limit: pageSize)
        guard listVersion == version else { return }
        let known = Set(changes.map(\.id))
        changes += page.filter { !known.contains($0.id) }
        hasMore = page.count == pageSize
      } catch {
        guard listVersion == version else { return }
        readFailed(error, bot: bot, client: client)
      }
      isLoadingMore = false
    }
  }

  /// The server answers 404 for a deleted bot, and rereading can't fix that.
  private func readFailed(_ error: Error, bot: String?, client: APIClient) {
    if bot != nil, (error as? APIError)?.statusCode == 404 {
      show(botID: nil, client: client)
    } else {
      readError = friendlyError(error)
    }
  }

  /// `settled` runs on either outcome, and a failure rereads what's shown: a failed revert may still
  /// have changed the server, and an old list invites reverting twice.
  public func revert(_ change: LearnedChange, client: APIClient, settled: @escaping @MainActor () -> Void) {
    guard reverting.insert(change.id).inserted else { return }
    let version = scope
    errors[change.id] = nil
    Task {
      do {
        let recorded = try await client.revertChange(change.id)
        guard scope == version else { return }
        prepend(recorded)
      } catch {
        guard scope == version else { return }
        errors[change.id] = friendlyError(error)
        read(limit: min(max(changes.count, pageSize), Self.largestRead), client: client)
      }
      reverting.remove(change.id)
      settled()
    }
  }

  /// A read that left before the revert can't be trusted to hold it, so it's dropped. A list still
  /// on its first read gets the revert from that read or the next.
  private func prepend(_ recorded: LearnedChange) {
    guard isLoaded, botID == nil || botID == recorded.agentID else { return }
    newList()
    changes.removeAll { $0.id == recorded.id }
    changes.insert(recorded, at: 0)
  }

  @discardableResult private func newList() -> Int {
    listVersion += 1
    isLoadingMore = false
    return listVersion
  }
}
