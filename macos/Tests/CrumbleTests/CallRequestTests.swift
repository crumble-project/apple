import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    @MainActor private func waitForCalls(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func savedCall(_ id: String, status: String) -> String {
        #"{"id":"\#(id)","agentId":"a1","number":"+4930123456","callee":"Dr. Weber","goal":"Book a visit","#
            + #""opening":"Hello, this is Bot.","status":"\#(status)","callId":"c1","conversationId":"v1","#
            + #""outcome":null,"error":null,"requestedAt":"2026-11-05T10:00:00Z","decidedAt":null,"endedAt":null}"#
    }

    @MainActor private func callModel(
        status: @escaping @Sendable () -> String, saved savedStatus: String = "ended",
        transcript: @escaping @Sendable (String) -> (Int, String)
    ) throws -> (AppModel, CallRequest) {
        let saved = savedCall("r1", status: savedStatus)
        let message = Message(
            id: "m1", role: "toolResult", toolName: CallRequest.toolName,
            toolDetails: try JSONDecoder().decode(JSONValue.self, from: Data(saved.utf8)))
        let request = try #require(CallRequest(message: message))
        let model = AppModel(client: StubProtocol.client { stubbed in
            let path = stubbed.url?.path ?? ""
            if path.hasSuffix("/transcript") { return transcript(path) }
            if path.hasSuffix("/call-requests") { return (200, "[" + self.savedCall("r1", status: status()) + "]") }
            return (404, "")
        })
        model.selectedAgentID = "a1"
        model.callPollInterval = .milliseconds(20)
        return (model, request)
    }

    private static let page = #"{"messages":[{"id":"t1","entryId":"e:1","role":"user","content":"Hello?"},"#
        + #"{"id":"t2","entryId":"e:2","role":"assistant","content":"Hi, this is Bot.","#
        + #""blocks":[{"type":"text","text":"Hi, this is Bot."}]}],"hasMore":false,"oldestEntryId":null}"#

    @MainActor @Test func openingACallLoadsItsTranscript() async throws {
        let (model, request) = try callModel(status: { "ended" }, transcript: { _ in (200, Self.page) })
        model.openCall(request)
        await model.watchCallTranscript()
        #expect(model.openCall?.loaded == true)
        #expect(model.openCall?.lines.map(\.text) == ["Hello?", "Hi, this is Bot."])
        #expect(model.openCall?.lines.map(\.speaker) == [.callee, .bot])
    }

    @MainActor @Test func aFailedTranscriptLoadIsMarked() async throws {
        let (model, request) = try callModel(status: { "ended" }, transcript: { _ in (500, "") })
        model.openCall(request)
        await model.watchCallTranscript()
        #expect(model.openCall?.failed == true)
        #expect(model.openCall?.loaded == false)
    }

    @MainActor @Test func theTranscriptReloadsWhileCallingAndOnceAfterItEnds() async throws {
        nonisolated(unsafe) var status = "calling"
        let (model, request) = try callModel(
            status: { status }, saved: "calling", transcript: { _ in (200, Self.page) })
        model.callRequestBoard.select("a1")
        model.openCall(request)
        let watching = Task { await model.watchCallTranscript() }
        await waitForCalls { StubProtocol.requests.filter { $0.url?.path.hasSuffix("/transcript") == true }.count >= 3 }
        #expect(StubProtocol.requests.filter { $0.url?.path.hasSuffix("/transcript") == true }.count >= 3)

        status = "ended"
        model.callRequestBoard.refresh(client: try #require(model.client))
        await waitForCalls { model.callRequestBoard.current(request).status == .ended }
        await watching.value
        let settled = StubProtocol.requests.filter { $0.url?.path.hasSuffix("/transcript") == true }.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(StubProtocol.requests.filter { $0.url?.path.hasSuffix("/transcript") == true }.count == settled)
    }

    @MainActor @Test func aLateTranscriptForAnotherCallIsDropped() async throws {
        nonisolated(unsafe) var other = false
        let (model, request) = try callModel(
            status: { "ended" },
            transcript: { _ in
                if !other { Thread.sleep(forTimeInterval: 0.15) }
                return (200, Self.page)
            })
        model.openCall(request)
        let first = Task { await model.watchCallTranscript() }
        try await Task.sleep(for: .milliseconds(30))
        var second = request
        second.id = "r2"
        other = true
        model.openCall(second)
        await first.value
        #expect(model.openCall?.request.id == "r2")
        #expect(model.openCall?.loaded == false)
        #expect(model.openCall?.lines.isEmpty == true)

        other = false
        model.openCall(request)
        let third = Task { await model.watchCallTranscript() }
        try await Task.sleep(for: .milliseconds(30))
        model.closeCall()
        await third.value
        #expect(model.openCall == nil)
    }
}
