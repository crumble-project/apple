import apfelkern
import Foundation
import Testing

@testable import Crumble

@Suite(.serialized)
struct DeliveryTimingTests {
    @MainActor private func initializedModel() -> (AppModel, ControlledDeliveryController) {
        let (client, controller) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        model.selectedAgentID = "a1"
        model.route = .agent("a1")
        model.snapshot = ChatSnapshot(status: "idle", agentId: "a1")
        return (model, controller)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @MainActor @Test func snapshotAcknowledgementWinsOverLateHTTPFailure() async throws {
        let (model, controller) = initializedModel()
        model.draft = "confirmed before response"
        let send = try #require(model.sendMessage())
        #expect(model.messages.first?.deliveryState == .sending)
        let requestID = model.messages.first?.requestId
        #expect(requestID != nil)
        #expect(await controller.waitForPosts(1))

        model.applySnapshot(
            ChatSnapshot(
                messages: [
                    Message(
                        id: "a1:1:0", role: "user", content: .string("confirmed before response"),
                        requestId: requestID)
                ], status: "idle", agentId: "a1"))
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.deliveryState == .confirmed)

        await controller.completePost(1, status: 500, body: #"{"error":"late failure"}"#)
        await send.value
        #expect(!model.sending)
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.deliveryState == .confirmed)
        #expect(model.draft.isEmpty)
        #expect(model.errorText.isEmpty)
    }

    @MainActor @Test func acceptedHTTPKeepsOptimisticRowUntilTranscriptAcknowledges() async throws {
        let (model, controller) = initializedModel()
        model.draft = "await transcript"
        let send = try #require(model.sendMessage())
        let requestID = model.messages.first?.requestId
        #expect(requestID != nil)
        #expect(await controller.waitForPosts(1))

        await controller.completePost(1, status: 202)
        await send.value
        #expect(!model.sending)
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.deliveryState == .sending)

        model.applySnapshot(
            ChatSnapshot(
                messages: [
                    Message(
                        id: "a1:2:0", role: "user", content: .string("await transcript"),
                        requestId: requestID)
                ], status: "idle", agentId: "a1"))
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.deliveryState == .confirmed)
    }

    @MainActor @Test func lateFailureDoesNotOverwriteANewerDraft() async throws {
        let (model, controller) = initializedModel()
        model.draft = "first send"
        let send = try #require(model.sendMessage())
        #expect(await controller.waitForPosts(1))
        model.draft = "typed while sending"

        await controller.completePost(1, status: 500, body: #"{"error":"busy"}"#)
        await send.value
        #expect(!model.sending && !model.errorText.isEmpty)
        #expect(model.draft == "typed while sending")
        #expect(model.messages.first?.deliveryState == .failed)
    }

    @MainActor @Test func changingBotsWhileSendIsOutstandingKeepsTheNewSelection() async throws {
        let (model, controller) = initializedModel()
        model.draft = "send on first bot"
        let send = try #require(model.sendMessage())
        #expect(await controller.waitForPosts(1))

        defer { model.cancelStream(preservingWork: false) }
        model.selectAgent("a2")
        #expect(await waitUntil { model.snapshot?.agentId == "a2" })
        model.draft = "draft for second bot"
        await controller.completePost(1, status: 500, body: #"{"error":"late failure"}"#)
        await send.value

        #expect(model.selectedAgentID == "a2")
        #expect(model.snapshot?.agentId == "a2")
        #expect(model.draft == "draft for second bot")
        #expect(model.errorText.isEmpty)
    }

    @MainActor @Test func replacingConnectionDropsAnOutstandingSend() async throws {
        let (model, oldController) = initializedModel()
        model.draft = "old connection send"
        let send = try #require(model.sendMessage())
        #expect(await oldController.waitForPosts(1))

        let previousGeneration = model.generation
        let (replacementClient, _) = ControlledDeliveryProtocol.client()
        defer {
            model.cancelStream(preservingWork: false)
            model.activityTask?.cancel()
        }
        model.applyConnection(replacementClient)
        #expect(model.generation == previousGeneration + 1)
        #expect(model.selectedAgentID.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.draftRequestID.isEmpty)

        await oldController.completePost(1, status: 500, body: #"{"error":"stale failure"}"#)
        await send.value
        #expect(await waitUntil { !model.loading })
        #expect(model.selectedAgentID.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.errorText.isEmpty)
    }
}
