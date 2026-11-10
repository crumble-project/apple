import Foundation
import Testing
@testable import apfelkern

private func reply(
  _ agent: String = "a1", group: String? = nil, origin: String = "chat"
) -> ActivityEvent {
  ActivityEvent(type: "reply", agentId: agent, agentName: "Atlas", origin: origin, groupId: group)
}

@Test func unreadCountsRepliesByChatAndSeeingAChatClearsOnlyThatChat() {
  var unread = UnreadCounts()
  #expect(unread.badgeLabel == nil)
  unread.add(reply())
  unread.add(reply())
  unread.add(reply("a2", group: "g1"))
  #expect(unread.total == 3)
  #expect(unread.badgeLabel == "3")
  unread.markSeen(.group("g1"))
  #expect(unread.total == 2)
  unread.markSeen(.memory)
  unread.markSeen(nil)
  #expect(unread.total == 2)
  unread.markSeen(.agent("a1"))
  #expect(unread.total == 0)
  #expect(unread.badgeLabel == nil)
}

@Test func unreadIgnoresBotToBotRepliesAndPreviews() {
  var unread = UnreadCounts()
  unread.add(reply(origin: "bot"))
  unread.add(ActivityEvent(type: "chat-preview", agentId: "a1", agentName: "Atlas", lastMessage: "Hi"))
  #expect(unread.total == 0)
}

@Test func memoryLineJoinsSourceAndAge() throws {
  let now = try #require(automationRunDate("2026-11-05T12:00:00.000Z"))
  var memory = Memory(
    id: "m", content: "x", updatedAt: "2026-11-05T10:00:00.000Z", source: MemorySource(kind: "owner"))
  #expect(memoryLine(memory, now: now) == "Added by you · " + ageLabel(now.addingTimeInterval(-7200), now: now))
  memory.source = nil
  #expect(memoryLine(memory, now: now)?.contains("·") == false)
  memory.updatedAt = nil
  #expect(memoryLine(memory, now: now) == nil)
}

@Test func ageUsesTheLargestUnitThatFits() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let locale = Locale.current.language.languageCode?.identifier
  guard locale == "en" else { return }
  #expect(ageLabel(now.addingTimeInterval(-30), now: now) == "this minute")
  #expect(ageLabel(now.addingTimeInterval(-300), now: now) == "5 minutes ago")
  #expect(ageLabel(now.addingTimeInterval(-7200), now: now) == "2 hours ago")
  #expect(ageLabel(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
  #expect(ageLabel(now.addingTimeInterval(-14 * 86_400), now: now) == "2 weeks ago")
  #expect(ageLabel(now.addingTimeInterval(-90 * 86_400), now: now) == "3 months ago")
  #expect(ageLabel(now.addingTimeInterval(-800 * 86_400), now: now) == "2 years ago")
}

@Test func searchMatchesFindEveryCaseInsensitiveOccurrence() {
  let text = "Ships on Thursdays, ships fast"
  #expect(searchMatches(of: " SHIPS ", in: text).map { String(text[$0]) } == ["Ships", "ships"])
  #expect(searchMatches(of: "  ", in: text).isEmpty)
  #expect(searchMatches(of: "aa", in: "aaa").count == 1)
}
