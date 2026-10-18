import apfelkern
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Crumble

struct LogicTests {
    @MainActor @Test func sidebarPreviewsUpdateWithoutOpeningTheBotChat() throws {
        let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))
        model.agents = [Agent(id: "a1", name: "Atlas", lastMessage: "Earlier"), Agent(id: "a2", name: "Beacon")]
        model.route = .memory
        let data = Data(
            #"{"type":"chat-preview","agentId":"a2","agentName":"Beacon","lastMessage":"A new reply from Beacon"}"#.utf8
        )
        let event = try JSONDecoder().decode(ActivityEvent.self, from: data)
        model.handleActivity(event)
        #expect(model.agents[0].lastMessage == "Earlier")
        #expect(model.agents[1].lastMessage == "A new reply from Beacon")
        #expect(model.route == .memory)
        #expect(model.messages.isEmpty)
        #expect(notification(for: event, in: NotificationContext(appActive: false, route: nil)) == nil)
        model.handleActivity(ActivityEvent(type: "chat-preview", agentId: "a2", agentName: "Beacon", lastMessage: ""))
        #expect(model.agents[1].lastMessage?.isEmpty == true)
    }

    @Test func sseRejectsSnapshotsWithoutAgent() throws {
        var parser = SSEParser()
        _ = try parser.feed("event: snapshot")
        _ = try parser.feed("data: {\"status\":\"idle\"}")
        #expect(throws: SSEParser.InvalidPayload.self) { try parser.feed("") }
    }

    @Test func mergeKeepsLoadedHistoryInEntryOrder() {
        let older = [Message(id: "a1:2:0", role: "user"), Message(id: "a1:10:0", role: "assistant")]
        let snapshot = [
            Message(id: "a1:10:0", role: "assistant", content: .string("updated")),
            Message(id: "a1:11:1", role: "user"), Message(id: "a1:11:0", role: "user")
        ]
        let merged = mergeMessages(older, snapshot)
        #expect(merged.map(\.id) == ["a1:2:0", "a1:10:0", "a1:11:0", "a1:11:1"])
        #expect(merged[1].text == "updated")
    }

    @Test func tasksNeedExactlyOneScheduleMode() {
        #expect(validateTask(name: "", prompt: "", cron: "", runAt: "") != nil)
        #expect(
            validateTask(name: "Daily", prompt: "Check inbox", cron: "0 9 * * *", runAt: "2026-10-18T09:00:00Z") != nil)
        #expect(validateTask(name: "Daily", prompt: "Check inbox", cron: "0 9 * * *", runAt: "") == nil)
        #expect(validateTask(name: "Once", prompt: "Check inbox", cron: "", runAt: "2026-10-18T09:00:00Z") == nil)
        #expect(validateTask(name: "Once", prompt: "Check inbox", cron: "", runAt: "tomorrow") != nil)
    }

    @Test func taskRunAtPreservesExplicitOffsetInstant() throws {
        #expect(taskRunDate("2026-10-18T12:10:00+02:00") == taskRunDate("2026-10-18T10:10:00Z"))
        let fractional = try #require(taskRunDate("2026-10-18T12:10:00.123Z"))
        let whole = try #require(taskRunDate("2026-10-18T12:10:00Z"))
        #expect(abs(fractional.timeIntervalSince(whole) - 0.123) < 0.000001)
        #expect(validateTask(name: "Task", prompt: "Hi", cron: "0 9 * * *", runAt: "", timezone: "Not/AZone") != nil)
    }

    @Test func requestIDsAreVersion4UUIDs() {
        #expect(
            newRequestID().wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
    }

    @Test func avatarSeedsAcceptLegacyValues() {
        let cases = ["bot:violet": "violet", "critters:violet": "violet", "sparkles": "a1", "😀": "a1", "": "a1"]
        for (avatar, seed) in cases {
            #expect(agentAvatarSeed(Agent(id: "a1", avatar: avatar)) == seed)
        }
        let first = BotLook(seed: "agent-seed")
        let second = BotLook(seed: "agent-seed")
        #expect(first == second)
    }

    @Test func chatHidesToolActivity() {
        let tool = Message(id: "a1:1:0", role: "assistant", blocks: .array([.object(["type": .string("toolCall")])]))
        let reply = Message(
            id: "a1:1:1", role: "assistant", content: .string("Hi"),
            blocks: .array([.object(["type": .string("text"), "text": .string("Hi")])]))
        #expect(!ChatRow.shownInChat(tool))
        #expect(ChatRow.shownInChat(reply))
    }

    @MainActor @Test func cancelledSheetDraftStaysReadable() throws {
        let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))
        model.openMCPForm("")
        @Bindable var bindable = model
        let item = try #require(model.mcpDraft)
        let draft = sheetBinding($bindable.mcpDraft, for: item)
        draft.wrappedValue.name = "Linear"
        #expect(model.mcpDraft?.name == "Linear")
        model.mcpDraft = nil  // Cancel; the closing sheet still redraws and may commit its fields.
        #expect(draft.wrappedValue.id == item.id)
        draft.wrappedValue.name = "Late write"
        #expect(model.mcpDraft == nil)
    }

    @Test func shiftReturnInsertsANewlineAtTheCaret() throws {
        let text = "hello world"
        let caret = text.index(text.startIndex, offsetBy: 5)
        let (edited, after) = insertingNewline(into: text, replacing: caret..<caret)
        #expect(edited == "hello\n world")
        #expect(edited[after...] == " world")
        let word = try #require(text.range(of: "world"))
        #expect(insertingNewline(into: text, replacing: word).text == "hello \n")
        #expect(insertingNewline(into: text, replacing: nil).text == "hello world\n")
    }

    @Test func filesBecomeAttachmentsTheServerAccepts() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appending(path: "notes.md")
        try Data("# Groceries".utf8).write(to: notes)
        let text = try loadAttachment(from: notes)
        #expect(text.mimeType.hasPrefix("text/") && text.data == Data("# Groceries".utf8))

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = folder.appending(path: "photo.tiff")
        try #require(image.tiffRepresentation).write(to: tiff)
        let converted = try loadAttachment(from: tiff)
        #expect(converted.mimeType == "image/jpeg" && converted.name == "photo.jpg")

        let pdf = folder.appending(path: "doc.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        #expect(throws: AttachmentError.self) { try loadAttachment(from: pdf) }
    }

    @Test func notificationsSkipWhatIsOnScreen() {
        let reply = ActivityEvent(
            type: "reply", agentId: "a1", agentName: "Atlas", origin: "owner", preview: "**Done**, two meetings.")
        #expect(
            notification(for: reply, in: NotificationContext(appActive: false, route: .agent("a1")))?.body
                == "Done, two meetings.")
        #expect(notification(for: reply, in: NotificationContext(appActive: true, route: .agent("a1"))) == nil)
        #expect(
            notification(for: reply, in: NotificationContext(appActive: true, route: .agent("a2")))?.title == "Atlas")
        var delegated = reply
        delegated.origin = "bot"
        #expect(notification(for: delegated, in: NotificationContext(appActive: false, route: nil)) == nil)
    }

    @Test func activityStreamPassesOnlyActivity() throws {
        var parser = SSEParser(accepting: ["activity"])
        _ = try parser.feed("event: heartbeat")
        _ = try parser.feed("data: {}")
        #expect(try parser.feed("") == nil)
        _ = try parser.feed("event: activity")
        _ = try parser.feed(#"data: {"type":"reply","agentId":"a1","agentName":"Atlas"}"#)
        #expect(try parser.feed("") != nil)
    }

    @Test func botCommunicationEventRetainsAttributionAndAppearsInChat() throws {
        let data = Data(
            #"""
            {"id":"exchange-1","role":"event","kind":"bot-message","content":"I asked how Bot2 feels.",
             "communication":{"executionId":"run-1","fromAgentId":"a1","fromName":"Atlas",
                              "toAgentId":"a2","toName":"Beacon","status":"done"}}
            """#.utf8)
        let message = try JSONDecoder().decode(Message.self, from: data)
        let rows = ChatRow.rows(messages: [message], snapshot: nil, hasMore: false)

        #expect(rows.count == 1)
        guard case .message(let retained) = rows[0] else {
            Issue.record("bot communication event was omitted from chat rows")
            return
        }
        #expect(retained.kind == "bot-message")
        #expect(retained.communication?.fromName == "Atlas")
        #expect(retained.communication?.toName == "Beacon")
        #expect(retained.communication?.status == "done")
    }

    @Test func chatRowsKeepPartialAssistantTextHiddenUntilCompletion() throws {
        let rows = ChatRow.rows(
            messages: [], snapshot: ChatSnapshot(status: "running", partial: "draft"), hasMore: false)

        #expect(rows.count == 1)
        guard case .thinking = rows[0] else {
            Issue.record("partial assistant text should render as a working indicator")
            return
        }
    }

    @Test func signInCallbacksCarryACodeOrAReason() throws {
        let callback = "dev.crumble.desktop:/oauth/callback"
        let result = try oauthResult(from: #require(URL(string: callback + "?code=abc&state=xyz")))
        #expect(result.code == "abc" && result.state == "xyz" && result.iss == nil)
        let issuedURL = try #require(
            URL(string: callback + "?code=abc&state=xyz&iss=https%3A%2F%2Fexecutor.sh%2Fapi%2Fauth"))
        let issued = try oauthResult(from: issuedURL)
        #expect(issued.iss == "https://executor.sh/api/auth")
        let declined = try #require(
            URL(string: callback + "?error=access_denied&error_description=User%20declined"))
        #expect(throws: SignInError.self) { try oauthResult(from: declined) }
        let missing = try #require(URL(string: callback))
        #expect(throws: SignInError.self) { try oauthResult(from: missing) }
    }

    @Test func markdownSplitsBlocks() {
        let blocks = MarkdownBlock.parse("Two meetings:\n\n- 09:00 Design\n- 14:30 Call\n\n```\ncode\n```")
        #expect(
            blocks == [
                .paragraph("Two meetings:"),
                .list([
                    .init(marker: "•", text: "09:00 Design", indent: 0),
                    .init(marker: "•", text: "14:30 Call", indent: 0)
                ]),
                .code("code")
            ])
    }
}
