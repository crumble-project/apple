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
        let client = StubProtocol.client { _ in (200, #"{"messages":[],"hasMore":false,"oldestEntryId":null}"#) }
        _ = try await client.codingJobHistory("a1", name: "fix login/ui", before: "e:1", limit: 50)
        let url = StubProtocol.requests.first?.url?.absoluteString
        #expect(url == "http://crumble.test/v1/agents/a1/coding-jobs/fix%20login%2Fui/history?limit=50&before=e%3A1")
    }

    @MainActor @Test func codingToggleFollowsCapabilitiesButKeepsExistingCoding() async {
        let model = AppModel(client: StubProtocol.client { request in
            request.url?.path == "/v1/capabilities" ? (200, #"{"coding":true,"desktop":false}"#) : (404, "")
        })
        let plain = AgentDraft(isNew: false, agentID: "a1")
        let coding = AgentDraft(isNew: false, agentID: "a1", toolsCoding: true)
        #expect(!model.offersCoding(for: plain))
        #expect(model.offersCoding(for: coding))
        model.loadCapabilities()
        await waitForJobs { model.capabilities != nil }
        #expect(model.offersCoding(for: plain))
    }

    @MainActor @Test func openingACodingJobLoadsItsHistory() async {
        let model = AppModel(client: StubProtocol.client { request in
            request.url?.path == "/v1/agents/a1/coding-jobs/fix/history"
                ? (200, #"{"messages":[{"id":"a1:1:0","entryId":"a1:1","role":"user","content":"Fix it"}],"hasMore":true,"#
                    + #""oldestEntryId":"a1:1"}"#)
                : (404, "")
        })
        model.selectedAgentID = "a1"
        model.openJob(.coding, "fix")
        await waitForJobs { model.jobHistory?.loaded == true }
        #expect(model.jobHistory?.messages.map(\.text) == ["Fix it"])
        #expect(model.jobHistory?.hasMore == true)
        #expect(model.jobHistory?.oldestEntryID == "a1:1")
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
        await waitForJobs { model.jobs["coding/fix"]?.isWorking == true }
        #expect(model.jobs["coding/fix"]?.isWorking == true)

        status = "idle"
        let report = Message(
            id: "a1:2:0", role: "user", content: .string("Done"),
            origin: MessageOrigin(kind: "coding", name: "fix"))
        model.applySnapshot(ChatSnapshot(messages: [started, report], agentId: "a1"))
        await waitForJobs { model.jobs["coding/fix"]?.isWorking == false }
        #expect(model.jobs["coding/fix"]?.isWorking == false)
        let recorded = Job(message: started)
        #expect(recorded.map { model.job($0).status } == "idle")
    }

    @MainActor @Test func desktopJobsRefreshAndOpenTheirOwnHistory() async {
        nonisolated(unsafe) var status = "working"
        let model = AppModel(client: StubProtocol.client { request in
            switch request.url?.path {
            case "/v1/agents/a1/desktop-jobs":
                (200, #"{"jobs":[{"name":"github","conversationId":"c2","status":"\#(status)","#
                    + #""usage":{"models":{"m":{"input":1000,"output":500,"cacheRead":0,"cost":{"total":0.002}}}}}]}"#)
            case "/v1/agents/a1/desktop-jobs/github/history":
                (200, #"{"messages":[{"id":"a1:3:0","entryId":"a1:3","role":"user","content":"Log in"}],"#
                    + #""hasMore":false,"oldestEntryId":null}"#)
            default:
                (404, "")
            }
        })
        model.selectedAgentID = "a1"
        let started = Message(
            id: "a1:1:0", role: "toolResult", toolName: "desktop",
            toolDetails: .object(["name": .string("github"), "status": .string("working")]))
        model.applySnapshot(ChatSnapshot(messages: [started], agentId: "a1"))
        await waitForJobs { model.jobs["desktop/github"]?.isWorking == true }
        #expect(model.jobs["desktop/github"]?.usage.map { usageLine($0, locale: Locale(identifier: "en_US")) }
            == "1,000 in · 500 out · $0.0020")

        status = "idle"
        let report = Message(
            id: "a1:2:0", role: "user", content: .string("Please log in"),
            origin: MessageOrigin(kind: "desktop", name: "github"))
        model.applySnapshot(ChatSnapshot(messages: [started, report], agentId: "a1"))
        await waitForJobs { model.jobs["desktop/github"]?.isWorking == false }
        #expect(model.jobs["coding/github"] == nil)

        model.openJob(.desktop, "github")
        await waitForJobs { model.jobHistory?.loaded == true }
        #expect(model.jobHistory?.messages.map(\.text) == ["Log in"])
    }

    @Test func desktopJobReportsStayBehindTheirCard() {
        let report = Message(
            id: "a1:2:0", role: "user", content: .string("Please log in"),
            origin: MessageOrigin(kind: "desktop", name: "github"))
        #expect(!ChatRow.shownInChat(report))
    }
}
