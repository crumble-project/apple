import Foundation
import Testing
@testable import Crumble

/// Focused coverage for the local-first chat contract. These tests live in the serialized
/// APIClientTests suite because they share its StubProtocol request recorder.
extension APIClientTests {
    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func chatModel(
        handler: @escaping (URLRequest) -> (Int, String)
    ) async -> AppModel {
        let model = AppModel(client: StubProtocol.client(handler))
        model.selectAgent("a1")
        await waitUntil { model.snapshot != nil }
        return model
    }

    @MainActor @Test func messageAppearsBeforeHTTPResponseAndSSEAckReconciles() async {
        let model = await chatModel { request in
            switch request.url?.path {
            case "/v1/agents/a1/chat":
                (200, #"{"agentId":"a1","status":"idle","messages":[]}"#)
            case "/v1/agents/a1/messages": (202, "")
            default: (404, "")
            }
        }

        model.draft = "instant"
        model.sendMessage()
        let optimistic = model.messages.first { $0.text == "instant" }
        #expect(optimistic?.deliveryState == .sending)
        let requestID = optimistic?.requestId
        #expect(requestID != nil)
        await waitUntil { StubProtocol.requests.filter { $0.url?.path == "/v1/agents/a1/messages" }.count == 1 }

        model.applySnapshot(ChatSnapshot(messages: [
            Message(id: "a1:1:0", role: "user", content: .string("instant"), requestId: requestID)
        ], status: "idle", agentId: "a1"))
        #expect(model.messages.filter { $0.text == "instant" }.count == 1)
        #expect(model.messages.first?.deliveryState == .confirmed)
    }

    @MainActor @Test func failedSendCanRetryWithTheSameRequestID() async {
        var attempts = 0
        let model = await chatModel { request in
            switch request.url?.path {
            case "/v1/agents/a1/chat":
                return (200, #"{"agentId":"a1","status":"idle","messages":[]}"#)
            case "/v1/agents/a1/messages":
                attempts += 1
                return attempts == 1 ? (500, #"{"error":"busy"}"#) : (202, "")
            default: return (404, "")
            }
        }

        model.draft = "retry me"
        model.sendMessage()
        await waitUntil { model.messages.first?.deliveryState == .failed }
        let failed = model.messages.first!
        model.retryMessage(failed)
        await waitUntil { StubProtocol.requests.filter { $0.url?.path == "/v1/agents/a1/messages" }.count == 2 }

        let bodies = StubProtocol.requests
            .filter { $0.url?.path == "/v1/agents/a1/messages" }
            .compactMap { $0.httpBody }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .compactMap { $0["requestId"] as? String }
        #expect(bodies.count == 2)
        #expect(failed.requestId == bodies[0])
        #expect(failed.requestId == bodies[1])
        #expect(model.messages.first?.deliveryState == .sending)
    }

    @MainActor @Test func identicalMessagesGetDistinctOptimisticIDs() async {
        let model = await chatModel { request in
            switch request.url?.path {
            case "/v1/agents/a1/chat":
                (200, #"{"agentId":"a1","status":"idle","messages":[]}"#)
            case "/v1/agents/a1/messages": (202, "")
            default: (404, "")
            }
        }

        model.draft = "same"
        model.sendMessage()
        model.draft = "same"
        model.sendMessage()
        let rows = model.messages.filter { $0.text == "same" }
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap(\.requestId)).count == 2)
        await waitUntil { StubProtocol.requests.filter { $0.url?.path == "/v1/agents/a1/messages" }.count == 2 }
    }

    @MainActor @Test func pendingMessageSurvivesAgentSwitch() async {
        let model = await chatModel { request in
            switch request.url?.path {
            case "/v1/agents/a1/chat", "/v1/agents/a2/chat":
                let id = request.url?.path.contains("a2") == true ? "a2" : "a1"
                return (200, "{\"agentId\":\"\(id)\",\"status\":\"idle\",\"messages\":[]}")
            case "/v1/agents/a1/messages": return (202, "")
            default: return (404, "")
            }
        }

        model.draft = "keep me"
        model.sendMessage()
        #expect(model.messages.contains { $0.text == "keep me" })
        model.selectAgent("a2")
        await waitUntil { model.snapshot?.agentId == "a2" }
        #expect(!model.messages.contains { $0.text == "keep me" })
        model.selectAgent("a1")
        await waitUntil { model.snapshot?.agentId == "a1" }
        #expect(model.messages.contains { $0.text == "keep me" })
    }
}
