import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Crumble

/// Serves canned responses and records requests, so client tests never touch the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let (status, body) = Self.handler?(recorded) ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func client(token: String = "", _ handler: @escaping (URLRequest) -> (Int, String)) -> APIClient {
        self.handler = handler
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(baseURL: "http://crumble.test/", token: token, session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized)
struct APIClientTests {
    @Test func agentsSendBearerAndDecode() async throws {
        let client = StubProtocol.client(token: "test-token") { _ in (200, #"[{"id":"a1","name":"Atlas","enabled":true}]"#) }
        let agents = try await client.agents()
        #expect(agents.map(\.name) == ["Atlas"])
        #expect(StubProtocol.requests.first?.url?.path == "/v1/agents")
        #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func updateAgentCanClearCapabilities() async throws {
        let client = StubProtocol.client { _ in (200, #"{"id":"a1"}"#) }
        _ = try await client.updateAgent("a1", patch: ["tools": .array([]), "skills": try JSONValue(encoding: [Skill]())])
        let body = String(decoding: StubProtocol.requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#""tools":[]"#) && body.contains(#""skills":[]"#))
    }

    @Test func chatContracts() async throws {
        let client = StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/agents/a1/chat/history":
                (200, #"{"messages":[{"entryId":"a1:8","role":"user","content":"older"}],"hasMore":false,"oldestEntryId":"a1:8"}"#)
            case "/v1/agents/a1/messages": (202, "")
            default: (404, "")
            }
        }
        let history = try await client.chatHistory("a1", before: "a1:42", limit: 100)
        #expect(history.messages?.first?.entryId == "a1:8")
        #expect(StubProtocol.requests.last?.url?.query == "before=a1%3A42&limit=100")
        try await client.sendChatMessage("a1", content: "hello", requestID: "req", replyTo: "a1:41")
        let body = String(decoding: StubProtocol.requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#""replyTo":"a1:41""#))
    }

    @Test func messagesCarryAttachments() async throws {
        let client = StubProtocol.client { _ in (202, "") }
        try await client.sendChatMessage("a1", content: "", requestID: "req", replyTo: "",
                                         attachments: [OutgoingAttachment(name: "dot.png", mimeType: "image/png", data: "AAAA")])
        let body = try JSONSerialization.jsonObject(with: StubProtocol.requests.last?.httpBody ?? Data()) as? [String: Any]
        #expect(body?["replyTo"] == nil)
        #expect((body?["attachments"] as? [[String: String]])?.first?["mimeType"] == "image/png")
        let message = try JSONDecoder().decode(Message.self, from: Data(#"{"id":"a1:5:0","role":"user","content":"","attachments":[{"name":"dot.png","mimeType":"image/png","size":70,"kind":"image"}]}"#.utf8))
        #expect(message.attachments?.first?.isImage == true)
        #expect(ChatRow.shownInChat(message))
    }

    @MainActor @Test func failedSendsKeepTheirAttachments() async throws {
        let client = StubProtocol.client { _ in (500, #"{"error":"busy"}"#) }
        let model = AppModel(client: client)
        model.snapshot = ChatSnapshot(status: "idle", agentId: "a1")
        model.attachments = [PendingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8))]
        model.sendMessage()
        #expect(model.attachments.isEmpty)
        while model.sending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.attachments.map(\.name) == ["notes.txt"])
        #expect(model.errorText.contains("busy"))
    }

    @Test func errorsCarryStatusAndBody() async throws {
        let client = StubProtocol.client { _ in (401, "bad token") }
        do {
            _ = try await client.agents()
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error.statusCode == 401 && error.body == "bad token")
            #expect(friendlyError(error) == "Authentication failed. Check the server token in Settings.")
        }
    }

    @Test func scheduleRunUnwrapsTheEnvelope() async throws {
        let client = StubProtocol.client { _ in (200, #"{"admitted":true,"result":{"id":"e1","status":"pending"}}"#) }
        #expect(try await client.runSchedule("s1").id == "e1")
    }

    @Test func chatEventsDeliverSnapshotsThenReportClosing() async throws {
        let client = StubProtocol.client { request in
            #expect(request.url?.path == "/v1/agents/a7/events")
            return (200, "event: heartbeat\ndata: {}\n\nevent: snapshot\ndata: {\"agentId\":\"a7\",\ndata: \"status\":\"running\"}\n\n")
        }
        let received = Received()
        do {
            try await client.chatEvents("a7") { await received.append($0) }
        } catch is SSEClosedError {}
        #expect(await received.payloads == ["{\"agentId\":\"a7\",\n\"status\":\"running\"}"])
    }
}

actor Received {
    var payloads: [String] = []
    func append(_ payload: String) { payloads.append(payload) }
}

struct LogicTests {
    @Test func sseRejectsSnapshotsWithoutAgent() throws {
        var parser = SSEParser()
        _ = try parser.feed("event: snapshot")
        _ = try parser.feed("data: {\"status\":\"idle\"}")
        #expect(throws: SSEParser.InvalidPayload.self) { try parser.feed("") }
    }

    @Test func mergeKeepsLoadedHistoryInEntryOrder() {
        let older = [Message(id: "a1:2:0", role: "user"), Message(id: "a1:10:0", role: "assistant")]
        let snapshot = [Message(id: "a1:10:0", role: "assistant", content: .string("updated")), Message(id: "a1:11:1", role: "user"), Message(id: "a1:11:0", role: "user")]
        let merged = mergeMessages(older, snapshot)
        #expect(merged.map(\.id) == ["a1:2:0", "a1:10:0", "a1:11:0", "a1:11:1"])
        #expect(merged[1].text == "updated")
    }

    @Test func tasksNeedExactlyOneScheduleMode() {
        #expect(validateTask(name: "", prompt: "", cron: "", runAt: "") != nil)
        #expect(validateTask(name: "Daily", prompt: "Check inbox", cron: "0 9 * * *", runAt: "2026-10-18T09:00:00Z") != nil)
        #expect(validateTask(name: "Daily", prompt: "Check inbox", cron: "0 9 * * *", runAt: "") == nil)
        #expect(validateTask(name: "Once", prompt: "Check inbox", cron: "", runAt: "2026-10-18T09:00:00Z") == nil)
        #expect(validateTask(name: "Once", prompt: "Check inbox", cron: "", runAt: "tomorrow") != nil)
    }

    @Test func requestIDsAreVersion4UUIDs() {
        #expect(newRequestID().wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
    }

    @Test func avatarSeedsAcceptLegacyValues() {
        let cases = ["bot:violet": "violet", "critters:violet": "violet", "sparkles": "a1", "😀": "a1", "": "a1"]
        for (avatar, seed) in cases {
            #expect(agentAvatarSeed(Agent(id: "a1", avatar: avatar)) == seed)
        }
        #expect(BotLook(seed: "agent-seed") == BotLook(seed: "agent-seed"))
    }

    @Test func chatHidesToolActivity() {
        let tool = Message(id: "a1:1:0", role: "assistant", blocks: .array([.object(["type": .string("toolCall")])]))
        let reply = Message(id: "a1:1:1", role: "assistant", content: .string("Hi"), blocks: .array([.object(["type": .string("text"), "text": .string("Hi")])]))
        #expect(!ChatRow.shownInChat(tool))
        #expect(ChatRow.shownInChat(reply))
    }

    @MainActor @Test func cancelledSheetDraftStaysReadable() {
        let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))
        model.openMCPForm("")
        @Bindable var bindable = model
        let item = model.mcpDraft!
        let draft = sheetBinding($bindable.mcpDraft, for: item)
        draft.wrappedValue.name = "Linear"
        #expect(model.mcpDraft?.name == "Linear")
        model.mcpDraft = nil // Cancel; the closing sheet still redraws and may commit its fields.
        #expect(draft.wrappedValue.id == item.id)
        draft.wrappedValue.name = "Late write"
        #expect(model.mcpDraft == nil)
    }

    @Test func shiftReturnInsertsANewlineAtTheCaret() {
        let text = "hello world"
        let caret = text.index(text.startIndex, offsetBy: 5)
        let (edited, after) = insertingNewline(into: text, replacing: caret..<caret)
        #expect(edited == "hello\n world")
        #expect(edited[after...] == " world")
        let word = text.range(of: "world")!
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
        try image.tiffRepresentation!.write(to: tiff)
        let converted = try loadAttachment(from: tiff)
        #expect(converted.mimeType == "image/jpeg" && converted.name == "photo.jpg")

        let pdf = folder.appending(path: "doc.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        #expect(throws: AttachmentError.self) { try loadAttachment(from: pdf) }
    }

    @Test func markdownSplitsBlocks() {
        let blocks = MarkdownBlock.parse("Two meetings:\n\n- 09:00 Design\n- 14:30 Call\n\n```\ncode\n```")
        #expect(blocks == [
            .paragraph("Two meetings:"),
            .list([.init(marker: "•", text: "09:00 Design", indent: 0), .init(marker: "•", text: "14:30 Call", indent: 0)]),
            .code("code"),
        ])
    }
}
