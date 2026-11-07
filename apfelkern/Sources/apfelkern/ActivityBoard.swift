import Foundation
import Observation

/// The Activity page's feed, newest first, narrowed by kind and bot. Pages come from the server's
/// cursor. Results that return after the filter or the connection changed are dropped.
@MainActor @Observable
public final class ActivityBoard {
  public private(set) var entries: [ActivityEntry] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  public private(set) var isLoadingMore = false
  /// The one kind the feed shows, or nil for all of them.
  public private(set) var kind: ActivityKind?
  /// The one bot the feed shows, or nil for every bot.
  public private(set) var botID: String?
  private var nextCursor: String?
  private var listVersion = 0
  private let pageSize: Int

  public init(pageSize: Int = 50) {
    self.pageSize = pageSize
  }

  public func reset() {
    listVersion += 1
    entries = []
    isLoaded = false
    readError = nil
    isLoadingMore = false
    kind = nil
    botID = nil
    nextCursor = nil
  }

  /// A page can run short while there is more, so this comes from the cursor alone.
  public var hasMore: Bool { nextCursor != nil }

  public var emptyText: String {
    kind == nil
      ? "Tool calls, bot messages, and skill and memory changes will appear here."
      : "Nothing of this kind yet."
  }

  public func show(kind: ActivityKind?, botID: String?, client: APIClient) {
    guard kind != self.kind || botID != self.botID else { return }
    self.kind = kind
    self.botID = botID
    entries = []
    isLoaded = false
    readError = nil
    nextCursor = nil
    refresh(client: client)
  }

  /// Back to the newest page, as the web does on refresh.
  public func refresh(client: APIClient) {
    listVersion += 1
    isLoadingMore = false
    let version = listVersion
    let (kind, bot) = (kind, botID)
    Task {
      do {
        let page = try await client.activityFeed(kind: kind, agentID: bot, limit: pageSize)
        guard listVersion == version else { return }
        entries = page.activities
        nextCursor = page.nextCursor
        isLoaded = true
        readError = nil
      } catch {
        guard listVersion == version else { return }
        failed(error, bot: bot, client: client)
      }
    }
  }

  public func loadMore(client: APIClient) {
    guard let cursor = nextCursor, !isLoadingMore else { return }
    let version = listVersion
    let (kind, bot) = (kind, botID)
    isLoadingMore = true
    Task {
      do {
        let page = try await client.activityFeed(kind: kind, agentID: bot, cursor: cursor, limit: pageSize)
        guard listVersion == version else { return }
        let known = Set(entries.map(\.id))
        entries += page.activities.filter { !known.contains($0.id) }
        nextCursor = page.nextCursor
        readError = nil
      } catch {
        guard listVersion == version else { return }
        failed(error, bot: bot, client: client)
      }
      if listVersion == version { isLoadingMore = false }
    }
  }

  /// A filter on a deleted bot goes back to every bot.
  private func failed(_ error: Error, bot: String?, client: APIClient) {
    if bot != nil, (error as? APIError)?.statusCode == 404 {
      show(kind: kind, botID: nil, client: client)
    } else {
      readError = friendlyError(error)
    }
  }
}
