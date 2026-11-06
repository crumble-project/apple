import Foundation

/// When a conversation last moved and what it last said, for a list like Messages.
/// The contract's bot and group lists carry neither time, so clients read it from the chat's history.
public struct ConversationSummary: Equatable, Sendable {
  public var date: Date?
  public var preview: String

  public init(date: Date?, preview: String) {
    self.date = date
    self.preview = preview
  }

  /// `messages` runs oldest first. Empty when nothing in them would show as a bubble.
  public init?(messages: [Message]) {
    guard let last = messages.last(where: Self.isBubble) else { return nil }
    self.init(
      date: last.timestamp.map { Date(timeIntervalSince1970: Double($0) / 1000) },
      preview: last.text)
  }

  private static func isBubble(_ message: Message) -> Bool {
    (message.role == "user" || message.role == "assistant") && shownInChat(message)
      && noticeTitle(message) == nil
  }
}

/// Bots and group chats in one list, the latest first. Conversations with no known time keep
/// their order after the rest.
public func orderedConversations<Item>(
  _ items: [Item], date: (Item) -> Date?
) -> [Item] {
  items.enumerated()
    .map { (offset: $0.offset, item: $0.element, date: date($0.element)) }
    .sorted { first, second in
      switch (first.date, second.date) {
      case let (left?, right?) where left != right: left > right
      case (.some, nil): true
      case (nil, .some): false
      default: first.offset < second.offset
      }
    }
    .map(\.item)
}

/// The Messages date column: a time today, then "Yesterday", a weekday, and a date.
public func conversationDateLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
  if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
  if calendar.isDateInYesterday(date, relativeTo: now) { return "Yesterday" }
  let days = calendar.dateComponents(
    [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
  ).day ?? .max
  if (0..<7).contains(days) { return date.formatted(.dateTime.weekday(.wide)) }
  return date.formatted(date: .numeric, time: .omitted)
}

extension Calendar {
  fileprivate func isDateInYesterday(_ date: Date, relativeTo now: Date) -> Bool {
    guard let yesterday = self.date(byAdding: .day, value: -1, to: now) else { return false }
    return isDate(date, inSameDayAs: yesterday)
  }
}

extension Route {
  public var isChat: Bool {
    switch self {
    case .agent, .group: true
    default: false
    }
  }
}
