import Foundation
import Testing

@testable import apfelkern

struct GroupChatSupportTests {
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

    @Test func wireMessagesCarryTheirSources() throws {
        let wire = try JSONDecoder().decode(Components.Schemas.TranscriptMessage.self, from: Data(#"""
            {"id":"g:1:0","entryId":"g:1","role":"assistant","content":"Hi",
             "sources":[{"url":"https://example.com","title":"Example"}],
             "presentation":{"text":"Presented","citations":[{"href":"https://example.com","title":"Example","site":"example.com"}]}}
            """#.utf8))
        let message = try Message(wire: wire)
        #expect(message.sources == [MessageSource(url: "https://example.com", title: "Example")])
        #expect(message.text == "Hi")
        #expect(message.presentation?.text == "Presented")
        #expect(message.presentation?.citations.first?.site == "example.com")
    }

    @Test func aGroupReplyIsLabelledWithItsBot() {
        let reply = Message(
            id: "1", role: "assistant", content: .string("Hi"), origin: MessageOrigin(kind: "bot", name: "Ada"))
        #expect(messageLabel(reply) == "Ada")
        #expect(messageLabel(Message(id: "2", role: "assistant", content: .string("Hi"))) == "Agent")
    }
}
