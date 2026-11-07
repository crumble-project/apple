import Foundation
import Testing

@testable import apfelkern

struct GroupChatSupportTests {
    private let sources = [
        MessageSource(url: "https://Example.com/guide/", title: "The Guide"),
        MessageSource(url: "https://example.com/other", title: "Other")
    ]

    @Test func groupRowsSkipTurnsWithNothingToShow() {
        let bot = MessageOrigin(kind: "bot", name: "Ada", agentId: "a1")
        let messages = [
            Message(id: "1", role: "assistant", content: .string("  \n"), origin: bot),
            Message(id: "2", role: "assistant", content: .string("Booked."), origin: bot),
            Message(
                id: "3", role: "user", content: .string(""),
                attachments: [AttachmentInfo(name: "a.png", mimeType: "image/png", size: 1, kind: "image")])
        ]
        let rows = GroupChatRow.rows(messages: messages, snapshot: nil, agents: [], hasMore: false)
        #expect(rows.map(\.id) == ["2", "3"])
    }

    @Test func aFailedTurnOfADeletedBotStillShows() {
        let group = GroupChat(id: "g", name: "Trip", memberIds: ["a1", "a2"], createdAt: "now", updatedAt: "now")
        let snapshot = GroupChatSnapshot(
            groupChat: group,
            activity: GroupActivity(members: [GroupMemberActivity(agentId: "gone", status: .idle, error: "Boom")]))
        let rows = GroupChatRow.rows(messages: [], snapshot: snapshot, agents: [], hasMore: false)
        guard case .failure(_, let name, let error)? = rows.first else {
            Issue.record("The failed turn is missing")
            return
        }
        #expect(name == "A bot")
        #expect(error == "Boom")
    }

    @Test func draftsLimitTheirNameAndKeepMembersInJoiningOrder() {
        #expect(!GroupDraft(name: String(repeating: "a", count: 81), memberIDs: ["a1", "a2"]).isValid)
        #expect(GroupDraft(name: String(repeating: "a", count: 80), memberIDs: ["a1", "a2"]).isValid)
        var draft = GroupDraft(memberIDs: ["a1", "a2"])
        draft.setMember("a3", included: true)
        draft.setMember("a1", included: false)
        draft.setMember("a2", included: true)
        #expect(draft.memberIDs == ["a3", "a2"])
    }

    @Test func onlyParenthesesThatHeldACitationGoAway() {
        let split = SourceCitations.split(
            "Call `run()` or run() first (source: [source](https://example.com/guide)) and ( ) stays.",
            sources: sources)
        #expect(split.text == "Call `run()` or run() first and ( ) stays.")
    }

    @Test func aBotChatReplyListsThePagesItsTurnRead() {
        let page: (String, String) -> JSONValue = { .object(["url": .string($0), "title": .string($1)]) }
        let result: (String, [JSONValue], Bool) -> Message = { tool, pages, failed in
            Message(
                id: UUID().uuidString, role: "toolResult", toolName: tool, isError: failed,
                toolDetails: .array(pages))
        }
        let messages = [
            Message(id: "ask", role: "user", content: .string("Where?")),
            result("web_search", [page("https://a.test", "A")], false),
            result("web_extract", [.object(["url": .string("https://b.test"), "error": .string("Gone")])], false),
            result("web_search", [page("https://failed.test", "Failed")], true),
            result("memory_search", [page("https://other.test", "Other")], false),
            Message(id: "first", role: "assistant", content: .string("Here.")),
            result("web_extract", [page("https://c.test", "C")], false),
            Message(id: "second", role: "assistant", content: .string("And here.")),
            Message(id: "next", role: "user", content: .string("Thanks")),
            Message(id: "third", role: "assistant", content: .string("Welcome."))
        ]
        let replies = SourceCitations.byReply(messages)
        #expect(replies["first"] == [MessageSource(url: "https://a.test", title: "A")])
        #expect(replies["second"]?.map(\.title) == ["A", "C"])
        #expect(replies["third"] == nil)
    }

    @Test func noticeKindFollowsWhatTheReplyWaitsFor() {
        func kind(_ waitingFor: String?) -> NoticeKind {
            NoticeKind(ActivityEvent(type: "reply", agentId: "a", agentName: "A", waitingFor: waitingFor))
        }
        #expect(kind(nil) == .reply && kind(nil).soundFile == nil)
        #expect(kind("approval").soundFile == "notice-approval.wav")
        #expect(kind("credential").soundFile == "notice-credential.wav")
        #expect(kind("login") == .credential)
    }

    @Test func aReplyEventKeepsWhatItWaitsFor() throws {
        let event = ActivityEvent(
            eventId: "e", serverId: "s", createdAt: "now", type: "reply", agentId: "a", agentName: "A",
            origin: "owner", preview: "Key?", waitingFor: "login")
        let decoded = try JSONDecoder().decode(ActivityEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded.waitingFor == "login")
    }

    @Test func citationsOfReadPagesBecomeChipsOnce() {
        let split = SourceCitations.split(
            "Pack light ([source](https://example.com/guide), [source](https://EXAMPLE.com/guide/#top)). "
                + "See [source](https://example.com/other).",
            sources: sources)
        #expect(split.text == "Pack light. See.")
        #expect(split.chips == [
            SourceChip(href: "https://example.com/guide", title: "The Guide"),
            SourceChip(href: "https://example.com/other", title: "Other")
        ])
    }

    @Test func citationsOfUnknownPagesAndCodeStayInTheText() {
        let text = "[source](https://elsewhere.com) and `[source](https://example.com/other)`\n"
            + "```\n[source](https://example.com/guide)\n```"
        let split = SourceCitations.split(text, sources: sources)
        #expect(split.text == text)
        #expect(split.chips.isEmpty)
    }

    @Test func wireMessagesCarryTheirSources() throws {
        let wire = try JSONDecoder().decode(Components.Schemas.TranscriptMessage.self, from: Data(#"""
            {"id":"g:1:0","entryId":"g:1","role":"assistant","content":"Hi",
             "sources":[{"url":"https://example.com","title":"Example"}]}
            """#.utf8))
        #expect(try Message(wire: wire).sources == [MessageSource(url: "https://example.com", title: "Example")])
    }

    @Test func aGroupReplyIsLabelledWithItsBot() {
        let reply = Message(
            id: "1", role: "assistant", content: .string("Hi"), origin: MessageOrigin(kind: "bot", name: "Ada"))
        #expect(messageLabel(reply) == "Ada")
        #expect(messageLabel(Message(id: "2", role: "assistant", content: .string("Hi"))) == "Agent")
    }
}
