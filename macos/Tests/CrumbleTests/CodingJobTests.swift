import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
    @MainActor private func waitForJobs(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func codingJobHistoryEncodesNameAndPaging() async throws {
        let client = StubProtocol.client { _ in (200, #"{"messages":[],"hasMore":false}"#) }
        _ = try await client.codingJobHistory("a1", name: "fix login/ui", before: "e:1", limit: 50)
        let url = StubProtocol.requests.first?.url?.absoluteString
        #expect(url == "http://crumble.test/v1/agents/a1/coding-jobs/fix%20login%2Fui/history?before=e%3A1&limit=50")
    }

    @MainActor @Test func codingToggleFollowsCapabilitiesButKeepsExistingCoding() async {
        let model = AppModel(client: StubProtocol.client { request in
            request.url?.path == "/v1/capabilities" ? (200, #"{"coding":true}"#) : (404, "")
        })
        let plain = AgentDraft(isNew: false, agentID: "a1")
        let coding = AgentDraft(isNew: false, agentID: "a1", toolsCoding: true)
        #expect(!model.offersCoding(for: plain))
        #expect(model.offersCoding(for: coding))
        model.loadCapabilities()
        await waitForJobs { model.capabilities != nil }
        #expect(model.offersCoding(for: plain))
    }

    @MainActor @Test func codingJobStatusRefreshesWhenItsReportArrives() async {
        nonisolated(unsafe) var status = "working"
        let model = AppModel(client: StubProtocol.client { request in
            request.url?.path == "/v1/agents/a1/coding-jobs"
                ? (200, #"{"jobs":[{"name":"fix","conversationId":"c1","status":"\#(status)"}]}"#) : (404, "")
        })
        model.selectedAgentID = "a1"
        let started = Message(
            id: "a1:1:0", role: "toolResult", toolName: "coding",
            toolDetails: .object(["name": .string("fix"), "status": .string("working")]))
        model.applySnapshot(ChatSnapshot(messages: [started], agentId: "a1"))
        await waitForJobs { model.codingJobs["fix"]?.isWorking == true }
        #expect(model.codingJobs["fix"]?.isWorking == true)

        status = "idle"
        let report = Message(
            id: "a1:2:0", role: "user", content: .string("Done"),
            origin: MessageOrigin(kind: "coding", name: "fix"))
        model.applySnapshot(ChatSnapshot(messages: [started, report], agentId: "a1"))
        await waitForJobs { model.codingJobs["fix"]?.isWorking == false }
        #expect(model.codingJobs["fix"]?.isWorking == false)
        let recorded = CodingJob(message: started)
        #expect(recorded.map { model.codingJob($0).status } == "idle")
    }
}
