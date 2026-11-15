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
                attachments: [AttachmentInfo(id: "f1", name: "a.png", mimeType: "image/png", size: 1)])
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

    @Test func aReplyShowsTheServersPresentationAndKeepsItsRawText() throws {
        let wire = try JSONDecoder().decode(Components.Schemas.TranscriptMessage.self, from: Data(#"""
            {"id":"g:1:0","entryId":"g:1","role":"assistant","content":"Pack light ([source](https://example.com/a)).",
             "replyReferences":[],"sources":[{"url":"https://example.com/a","title":"Guide"}],
             "presentation":{"text":"Pack light.","citations":[
               {"href":"https://example.com/a","title":"Guide","site":"example.com"}]}}
            """#.utf8))
        let message = try Message(wire: wire)
        #expect(message.text == "Pack light ([source](https://example.com/a)).")
        #expect(message.presentedText == "Pack light.")
        #expect(message.citations == [Citation(href: "https://example.com/a", site: "example.com", title: "Guide")])

        let plain = Message(id: "2", role: "assistant", content: .string("See [source](https://example.com/a)."))
        #expect(plain.presentedText == "See [source](https://example.com/a).")
        #expect(plain.citations.isEmpty)
    }

    @Test func aGroupReplyIsLabelledWithItsBot() {
        let reply = Message(
            id: "1", role: "assistant", content: .string("Hi"), origin: MessageOrigin(kind: "bot", name: "Ada"))
        #expect(messageLabel(reply) == "Ada")
        #expect(messageLabel(Message(id: "2", role: "assistant", content: .string("Hi"))) == "Agent")
    }
}
