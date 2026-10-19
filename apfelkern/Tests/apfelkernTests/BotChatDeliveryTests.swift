import apfelkern
import Foundation
import Testing

struct BotChatDeliveryTests {
    @Test func stageRetainsReplyAndAttachmentMetadata() {
        var delivery = BotChatDelivery()
        let image = PendingAttachment(name: "dot.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let send = BotChatDelivery.Send(
            content: "hello", replyTo: "a1:4", attachments: [image], replyPreview: "earlier")
        let row = delivery.stage(send, botID: "a1", requestID: "request")
        #expect(row.id == "local:request")
        #expect(row.requestId == "request")
        #expect(row.deliveryState == .sending)
        #expect(row.replyTo == "a1:4")
        #expect(row.replyPreview == "earlier")
        #expect(row.attachments == [AttachmentInfo(name: "dot.png", mimeType: "image/png", size: 3, kind: "image")])
        #expect(delivery.preview(botID: "a1") == "hello")
        #expect(delivery.imageData(botID: "a1", requestID: "request", index: 0) == image.data)
        #expect(delivery.imageData(botID: "a1", requestID: "request", index: 1) == nil)
    }

    @Test func acceptanceRetainsPendingRowUntilSnapshotAcknowledgement() {
        var delivery = BotChatDelivery()
        let image = PendingAttachment(name: "dot.png", mimeType: "image/png", data: Data([1]))
        let send = BotChatDelivery.Send(content: "", replyTo: "", attachments: [image])
        _ = delivery.stage(send, botID: "a1", requestID: "request")
        #expect(delivery.preview(botID: "a1") == "Attachment: dot.png")
        delivery.accepted(botID: "a1", requestID: "request")
        #expect(delivery.messages(botID: "a1").first?.deliveryState == .sending)
        #expect(delivery.imageData(botID: "a1", requestID: "request", index: 0) == image.data)
        #expect(delivery.preview(botID: "a1") == nil)
        delivery.acknowledge(botID: "a1", requestIDs: ["request"])
        #expect(delivery.messages(botID: "a1").isEmpty)
        #expect(delivery.imageData(botID: "a1", requestID: "request", index: 0) == nil)
        let lateFailure = delivery.fail(botID: "a1", requestID: "request")
        let retry = delivery.beginRetry(botID: "a1", requestID: "request")
        #expect(!lateFailure)
        #expect(retry == nil)
    }

    @Test func failureRetainsOriginalRetryPayload() {
        var delivery = BotChatDelivery()
        let file = PendingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        let send = BotChatDelivery.Send(content: "read", replyTo: "a1:4", attachments: [file])
        _ = delivery.stage(send, botID: "a1", requestID: "request")
        let failed = delivery.fail(botID: "a1", requestID: "request")
        #expect(failed)
        #expect(delivery.messages(botID: "a1").first?.deliveryState == .failed)
        #expect(delivery.preview(botID: "a1") == nil)
        let retry = delivery.beginRetry(botID: "a1", requestID: "request")
        #expect(retry?.content == send.content)
        #expect(retry?.replyTo == send.replyTo)
        #expect(retry?.attachments.map(\.id) == [file.id])
        #expect(retry?.attachments.first?.data == file.data)
        #expect(delivery.messages(botID: "a1").first?.requestId == "request")
        #expect(delivery.messages(botID: "a1").first?.deliveryState == .sending)
        #expect(delivery.preview(botID: "a1") == nil)
        #expect(delivery.imageData(botID: "a1", requestID: "request", index: 0) == nil)
    }

    @Test func olderCompletionsPreserveNewerPreviewAndBotIsolation() {
        var delivery = BotChatDelivery()
        let send = BotChatDelivery.Send(content: "same", replyTo: "", attachments: [])
        _ = delivery.stage(send, botID: "a1", requestID: "first")
        _ = delivery.stage(send, botID: "a1", requestID: "second")
        _ = delivery.stage(send, botID: "a2", requestID: "first")
        delivery.accepted(botID: "a1", requestID: "first")
        #expect(delivery.preview(botID: "a1") == "same")
        let failed = delivery.fail(botID: "a1", requestID: "first")
        #expect(failed)
        #expect(delivery.preview(botID: "a1") == "same")
        delivery.acknowledge(botID: "a1", requestIDs: ["first"])
        #expect(delivery.messages(botID: "a1").map(\.requestId) == ["second"])
        #expect(delivery.preview(botID: "a1") == "same")
        #expect(delivery.messages(botID: "a2").first?.deliveryState == .sending)
        delivery.acknowledge(botID: "a1", requestIDs: ["second"])
        #expect(delivery.preview(botID: "a1") == nil)
        #expect(delivery.preview(botID: "a2") == "same")
    }

    @Test func resetDropsAllPendingDeliveryState() {
        var delivery = BotChatDelivery()
        let send = BotChatDelivery.Send(content: "hello", replyTo: "", attachments: [])
        for bot in ["a1", "a2"] {
            _ = delivery.stage(send, botID: bot, requestID: "request")
        }
        delivery.reset()
        for bot in ["a1", "a2"] {
            #expect(delivery.messages(botID: bot).isEmpty)
            #expect(delivery.preview(botID: bot) == nil)
            let lateFailure = delivery.fail(botID: bot, requestID: "request")
            #expect(!lateFailure)
        }
    }
}
