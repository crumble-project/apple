import Foundation
import Testing

@testable import apfelkern

@Suite struct ConversationsTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func theLatestComesFirstAndUnknownTimesKeepTheirOrder() {
    let dates: [String: Date] = ["old": now.addingTimeInterval(-500), "new": now]
    let ordered = orderedConversations(["a", "old", "b", "new"]) { dates[$0] }
    #expect(ordered == ["new", "old", "a", "b"])
  }

  @Test func aSummaryComesFromTheLastBubble() throws {
    let reply = Message(id: "1", role: "user", content: .string("Done"), timestamp: 1_800_000_000_000)
    let tool = Message(id: "2", role: "toolResult", content: .string("hidden"))
    let summary = try #require(ConversationSummary(messages: [reply, tool]))
    #expect(summary.preview == "Done")
    #expect(summary.date == Date(timeIntervalSince1970: 1_800_000_000))
  }

  @Test func nothingToShowHasNoSummary() {
    #expect(ConversationSummary(messages: [Message(id: "1", role: "toolResult", content: .string("hidden"))]) == nil)
  }

  @Test func datesReadLikeMessages() throws {
    let calendar = Calendar.current
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
    let lastWeek = try #require(calendar.date(byAdding: .day, value: -3, to: now))
    let older = try #require(calendar.date(byAdding: .day, value: -20, to: now))
    #expect(conversationDateLabel(now, now: now) == now.formatted(date: .omitted, time: .shortened))
    #expect(conversationDateLabel(yesterday, now: now) == "Yesterday")
    #expect(conversationDateLabel(lastWeek, now: now) == lastWeek.formatted(.dateTime.weekday(.wide)))
    #expect(conversationDateLabel(older, now: now) == older.formatted(date: .numeric, time: .omitted))
  }
}
