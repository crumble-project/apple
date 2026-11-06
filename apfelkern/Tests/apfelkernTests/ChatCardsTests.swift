import Foundation
import Testing

@testable import apfelkern

struct ChatCardsTests {
    @Test func aDesktopScreenshotShowsOnlyWhenItSucceeded() {
        let shot = Message(id: "1", role: "toolResult", toolName: "desktop_screenshot")
        let failed = Message(id: "2", role: "toolResult", toolName: "desktop_screenshot", isError: true)
        #expect(shot.isDesktopScreenshot)
        #expect(shownInChat(shot))
        #expect(!shownInChat(failed))
    }

    @Test func aJobFailureNamesItsJob() throws {
        let message = Message(
            id: "1", role: "event", content: .string("coding job fix failed"), kind: "job-failure",
            origin: MessageOrigin(kind: "coding", name: "fix"))
        let failure = try #require(JobFailure(message: message))
        #expect(failure.kind == .coding)
        #expect(failure.name == "fix")
        #expect(failure.title == "Coding job fix failed")
        #expect(shownInChat(message))
    }

    @Test func aJobFailureNeedsAJobOrigin() {
        let wrongOrigin = Message(
            id: "1", role: "event", content: .string("x"), kind: "job-failure",
            origin: MessageOrigin(kind: "task", name: "t"))
        let wrongKind = Message(
            id: "2", role: "event", content: .string("x"), kind: "reset",
            origin: MessageOrigin(kind: "desktop", name: "d"))
        #expect(JobFailure(message: wrongOrigin) == nil)
        #expect(JobFailure(message: wrongKind) == nil)
    }

    @Test(arguments: [
        (MessageOrigin(kind: "script", name: "Backup"), "Script automation · Backup"),
        (MessageOrigin(kind: "event", name: "Triage", source: "GitHub"), "Automation · Triage, event from GitHub"),
        (MessageOrigin(kind: "event", name: "Triage"), "Automation · Triage, event from a deleted source"),
        (MessageOrigin(kind: "bot_request"), "Bot request"),
        (MessageOrigin(kind: "task", name: "Digest"), "Automation · Digest"),
        (MessageOrigin(kind: "credential", name: "API key"), "Credential · API key"),
        (MessageOrigin(kind: "bot", name: "Ada"), "From Ada")
    ])
    func automatedPromptsCollapse(origin: MessageOrigin, title: String) {
        #expect(noticeTitle(Message(id: "1", role: "user", origin: origin)) == title)
    }

    @Test func ownerMessagesStayBubbles() {
        #expect(noticeTitle(Message(id: "1", role: "user")) == nil)
        let gateway = MessageOrigin(kind: "owner", via: "discord")
        #expect(noticeTitle(Message(id: "2", role: "user", origin: gateway)) == nil)
        #expect(noticeTitle(Message(id: "3", role: "assistant", origin: MessageOrigin(kind: "script"))) == nil)
    }

    @Test func gatewaysKeepTheirIDWhenUnknown() {
        #expect(gatewayLabel("discord") == "Discord")
        #expect(gatewayLabel("matrix") == "matrix")
    }

    @Test func theWireOriginCarriesGatewayAndSource() throws {
        let wire = """
            {"id": "1", "entryId": "e", "role": "user", "content": "hi",
             "origin": {"kind": "owner", "via": "discord", "source": "GitHub"}}
            """
        let message = try Message(
            wire: JSONDecoder().decode(Components.Schemas.TranscriptMessage.self, from: Data(wire.utf8)))
        #expect(message.origin?.via == "discord")
        #expect(message.origin?.source == "GitHub")
    }

    private func call(_ names: String...) -> Message {
        let blocks = names.map { JSONValue.object(["type": .string("toolCall"), "name": .string($0)]) }
        return Message(id: "c", role: "assistant", blocks: .array(blocks))
    }

    @Test func workingReadsTheTurn() {
        let running = ChatSnapshot(status: "running")
        let cases: [(Message?, Working)] = [
            (nil, .thinking),
            (Message(id: "u", role: "user"), .thinking),
            (call("web_search", "memory"), .searching),
            (call("history_read"), .searching),
            (call("memory"), .remembering),
            (call("bash"), .tinkering),
            (Message(id: "t", role: "toolResult", isError: true), .struggling),
            (Message(id: "t", role: "toolResult"), .thinking)
        ]
        for (last, working) in cases {
            #expect(Working(snapshot: running, messages: last.map { [$0] } ?? []) == working)
        }
    }

    @Test func workingIgnoresTheOwnersPendingMessage() {
        let pending = Message(id: "p", role: "user", deliveryState: .sending)
        #expect(Working(snapshot: ChatSnapshot(status: "running"), messages: [call("memory"), pending]) == .remembering)
    }

    @Test func workingFollowsTheStatus() {
        #expect(Working(snapshot: nil, messages: []) == .idle)
        #expect(Working(snapshot: ChatSnapshot(status: "idle"), messages: []) == .idle)
        #expect(Working(snapshot: ChatSnapshot(status: "failed"), messages: []) == .failed)
        #expect(Working(snapshot: ChatSnapshot(status: "running", partial: "Hi"), messages: [call("bash")]) == .writing)
        #expect(Working(snapshot: ChatSnapshot(status: "running", partial: " \n"), messages: []) == .thinking)
    }

    @Test func workingLabelsMatchTheWeb() {
        #expect(Working.searching.label == "Searching")
        #expect(Working.remembering.label == "Remembering")
        #expect(Working.tinkering.label == "Using tools")
        #expect(Working.struggling.label == "Retrying")
    }

    @Test func mermaidFencesBecomeDiagrams() {
        let blocks = MarkdownBlock.parse("```mermaid\nflowchart LR\n  A --> B\n```\n\n```swift\nlet a = 1\n```")
        #expect(blocks == [.diagram("flowchart LR\n  A --> B"), .code("let a = 1")])
    }

    @Test func anOpenMermaidFenceRunsToTheEnd() {
        #expect(MarkdownBlock.parse("```mermaid\ngraph TD") == [.diagram("graph TD")])
    }

    @Test func markdownTablesParse() {
        #expect(
            MarkdownBlock.parse("| A | B |\n|---|--:|\n| 1 | 2 |")
                == [.table(columns: ["A", "B"], rows: [["1", "2"]], trailing: [1])])
    }
}
