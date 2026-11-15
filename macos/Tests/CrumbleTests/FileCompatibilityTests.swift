import apfelkern
import AppKit
import Foundation
import Testing

@testable import Crumble

private func uploadFixture(_ id: String) -> String {
    #"{"file":{"id":"\#(id)","name":"file","mimeType":"text/plain","size":2,"createdAt":"now"},"existed":false}"#
}

private func pngData() -> Data {
    let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else { preconditionFailure("Expected PNG data") }
    return png
}

private func imageMessage(_ entry: String, file: AttachmentInfo) -> Message {
    Message(id: "a1:\(entry):0", entryId: "a1:\(entry)", role: "user", attachments: [file])
}

private let dot = AttachmentInfo(id: "f1", name: "dot.png", mimeType: "image/png", size: 70)

private let tripFixture = """
    {"groupChat":{"id":"trip","name":"Trip","memberIds":["a1","a2"],"createdAt":"now","updatedAt":"now"},
     "activity":{"paused":false,"botTurns":0,"members":[]},
     "messages":[{"id":"trip:1:0","entryId":"trip:1","replyReferences":[],"role":"user","content":"Map",
       "files":[{"id":"g1","name":"map.png","mimeType":"image/png","size":70}]}],
     "hasMore":false,"oldestEntryId":"trip:1","updatedAt":1}
    """

/// Attachments upload before their message and are fetched by file ID, as the current server contract requires.
extension APIClientTests {
    @MainActor private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func requests(_ path: String) -> [URLRequest] {
        StubProtocol.requests.filter { $0.url?.path == path }
    }

    private func bodies(_ path: String) -> [JSONValue] {
        requests(path).compactMap { $0.httpBody }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    @MainActor private func botChat(handler: @escaping (URLRequest) -> (Int, String)) async -> AppModel {
        let model = AppModel(client: StubProtocol.client { request in
            request.url?.path == "/v1/agents/a1/chat" ? (200, chatFixture()) : handler(request)
        })
        model.selectAgent("a1")
        await waitFor { model.snapshot != nil }
        return model
    }

    @MainActor @Test func botSendsUploadRawBytesThenCarryFileIDs() async {
        let model = await botChat { request in
            switch request.url?.path {
            case "/v1/agents/a1/files": (201, uploadFixture("f1"))
            case "/v1/agents/a1/messages": (202, executionFixture())
            default: (404, "")
            }
        }
        defer { model.cancelStream(preservingWork: false) }
        model.draft = "Read this"
        model.attachments = [PendingAttachment(name: "notes ü.txt", mimeType: "text/plain", data: Data("hi".utf8))]
        await model.sendMessage()?.value

        let upload = requests("/v1/agents/a1/files")
        #expect(upload.count == 1)
        #expect(upload.first?.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        #expect(upload.first?.value(forHTTPHeaderField: "X-File-Name") == "notes%20%C3%BC.txt")
        #expect(upload.first?.httpBody == Data("hi".utf8))
        let body = bodies("/v1/agents/a1/messages").first
        #expect(body?["files"] == .array([.string("f1")]))
        #expect(body?["attachments"] == nil)
        #expect(model.messages.last?.deliveryState == .sending)
        #expect(model.messages.last?.attachments?.first?.name == "notes ü.txt")
    }

    @MainActor @Test func aRetryUploadsOnlyTheFilesAFailedAttemptMissed() async {
        var failedOnce = false
        let model = await botChat { request in
            switch request.url?.path {
            case "/v1/agents/a1/files":
                let name = request.value(forHTTPHeaderField: "X-File-Name") ?? ""
                if name == "b.txt", !failedOnce {
                    failedOnce = true
                    return (503, #"{"error":"busy"}"#)
                }
                return (201, uploadFixture("id-" + name))
            case "/v1/agents/a1/messages": return (202, executionFixture())
            default: return (404, "")
            }
        }
        defer { model.cancelStream(preservingWork: false) }
        let files = ["a.txt", "b.txt"].map { PendingAttachment(name: $0, mimeType: "text/plain", data: Data($0.utf8)) }
        model.draft = "Both"
        model.attachments = files
        await model.sendMessage()?.value
        guard let failed = model.messages.last, failed.deliveryState == .failed else {
            Issue.record("The send should fail on the second upload")
            return
        }
        #expect(requests("/v1/agents/a1/messages").isEmpty)
        // Bot failures put the message back in the composer, as before.
        #expect(model.draft == "Both")
        #expect(model.attachments.map(\.id) == files.map(\.id))

        model.retryMessage(failed)
        await waitFor { !requests("/v1/agents/a1/messages").isEmpty }
        let names = requests("/v1/agents/a1/files").compactMap { $0.value(forHTTPHeaderField: "X-File-Name") }
        #expect(names == ["a.txt", "b.txt", "b.txt"])
        let body = bodies("/v1/agents/a1/messages").first
        #expect(body?["files"] == .array([.string("id-a.txt"), .string("id-b.txt")]))
        #expect(body?["requestId"] == .string(failed.requestId ?? ""))
    }

    @MainActor @Test func aDeletedFileRejectionUploadsAgainWhileAmbiguousFailuresReuseUploads() async {
        var uploads = 0
        var sends = 0
        let model = await botChat { request in
            switch request.url?.path {
            case "/v1/agents/a1/files":
                uploads += 1
                return (201, uploadFixture("f\(uploads)"))
            case "/v1/agents/a1/messages":
                sends += 1
                switch sends {
                case 1: return (503, #"{"error":"busy"}"#)
                case 2: return (400, #"{"error":"notes.txt was deleted from the library"}"#)
                default: return (202, executionFixture())
                }
            default: return (404, "")
            }
        }
        defer { model.cancelStream(preservingWork: false) }
        model.attachments = [PendingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("n".utf8))]
        await model.sendMessage()?.value
        for attempt in 2...3 {
            guard let failed = model.messages.last, failed.deliveryState == .failed else {
                Issue.record("Attempt \(attempt - 1) should fail")
                return
            }
            model.retryMessage(failed)
            await waitFor { requests("/v1/agents/a1/messages").count == attempt }
        }
        let sent = bodies("/v1/agents/a1/messages")
        #expect(sent.map { $0["files"] } == [
            .array([.string("f1")]), .array([.string("f1")]), .array([.string("f2")])
        ])
        #expect(Set(sent.compactMap { $0["requestId"] }).count == 1)
        #expect(requests("/v1/agents/a1/files").map(\.httpBody) == [Data("n".utf8), Data("n".utf8)])
    }

    @MainActor @Test func deletedTranscriptFilesHideCachedImagesAndAreNeverFetched() async {
        let model = await botChat { _ in (404, "") }
        defer { model.cancelStream(preservingWork: false) }
        StubProtocol.files["/v1/agents/a1/files/f1"] = pngData()
        model.applySnapshot(ChatSnapshot(messages: [imageMessage("1", file: dot)], status: "idle", agentId: "a1"))
        await model.loadAttachmentImage(entryID: "a1:1", index: 0)
        #expect(requests("/v1/agents/a1/files/f1").count == 1)
        #expect(model.messages.first.flatMap { model.attachmentImage(message: $0, index: 0) } != nil)

        // A newer message lists the same file as deleted; the older one stops showing it at once.
        model.applySnapshot(ChatSnapshot(
            messages: [imageMessage("1", file: dot), imageMessage("2", file: .deleted("f1"))],
            status: "idle", agentId: "a1"))
        #expect(model.messages.map { $0.attachments?.first?.deleted } == [true, true])
        #expect(model.messages.allSatisfy { model.attachmentImage(message: $0, index: 0) == nil })
        await model.loadAttachmentImage(entryID: "a1:1", index: 0)
        await model.loadAttachmentImage(entryID: "a1:2", index: 0)
        #expect(requests("/v1/agents/a1/files/f1").count == 1)
        #expect(!StubProtocol.requests.contains { $0.url?.path.contains("/attachments/") == true })
    }

    @MainActor @Test func aDownloadThatFinishesAfterDeletionIsNotShown() async {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        defer { model.cancelStream(preservingWork: false) }
        model.selectAgent("a1")
        await waitFor { model.snapshot != nil }
        model.applySnapshot(ChatSnapshot(messages: [imageMessage("1", file: dot)], status: "idle", agentId: "a1"))
        await controller.hold("/v1/agents/a1/files/f1")
        let download = Task { await model.loadAttachmentImage(entryID: "a1:1", index: 0) }
        #expect(await controller.waitForHeld("/v1/agents/a1/files/f1"))
        model.applySnapshot(ChatSnapshot(
            messages: [imageMessage("1", file: .deleted("f1"))], status: "idle", agentId: "a1"))
        await controller.release("/v1/agents/a1/files/f1", data: pngData())
        await download.value
        #expect(model.attachmentImages.isEmpty)
    }

    @MainActor @Test func groupAttachmentsUploadToTheGroupAndDownloadByFileID() async {
        let model = AppModel(client: StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/group-chats/trip/chat": (200, tripFixture)
            case "/v1/group-chats/trip/events": (200, "")
            case "/v1/group-chats/trip/files": (201, uploadFixture("g2"))
            case "/v1/group-chats/trip/messages": (201, #"{"requestId":"r","entryId":"trip:2"}"#)
            default: (404, "")
            }
        })
        defer { model.leaveGroup() }
        StubProtocol.files["/v1/group-chats/trip/files/g1"] = pngData()
        model.selectGroup("trip")
        await waitFor { model.groupSnapshot != nil }
        await model.loadAttachmentImage(entryID: "trip:1", index: 0)
        #expect(requests("/v1/group-chats/trip/files/g1").count == 1)
        #expect(model.messages.first.flatMap { model.attachmentImage(message: $0, index: 0) } != nil)

        let route = pngData()
        model.attachments = [PendingAttachment(name: "route.png", mimeType: "image/png", data: route)]
        model.replyTo = model.messages.first
        await model.sendGroupMessage()?.value
        #expect(requests("/v1/group-chats/trip/files").first?.httpBody == route)
        let body = bodies("/v1/group-chats/trip/messages").first
        #expect(body?["files"] == .array([.string("g2")]))
        #expect(body?["replyTo"] == .string("trip:1"))
        // Until the snapshot confirms it, the row shows the image from the bytes it kept.
        #expect(model.messages.last.flatMap { model.attachmentImage(message: $0, index: 0) } != nil)
    }

    @MainActor @Test func anUploadFromAPreviousConnectionNeitherSendsNorChangesTheNewOne() async {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        defer { model.cancelStream(preservingWork: false) }
        model.selectAgent("a1")
        await waitFor { model.snapshot != nil }
        await controller.hold("/v1/agents/a1/files")
        model.attachments = [PendingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("n".utf8))]
        let send = model.sendMessage()
        #expect(await controller.waitForHeld("/v1/agents/a1/files"))

        let (next, _) = ControlledDeliveryProtocol.client()
        model.applyConnection(next)
        model.draft = "On the new server"
        await controller.release("/v1/agents/a1/files", body: uploadFixture("f1"), status: 201)
        await send?.value
        #expect(await controller.observedPostCount() == 0)
        #expect(model.messages.isEmpty)
        #expect(model.draft == "On the new server")
        #expect(model.attachments.isEmpty)
        #expect(model.errorText.isEmpty)
    }
}
