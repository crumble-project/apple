import apfelkern
import Foundation
import Testing

@testable import Crumble

extension APIClientTests {
  private static let waitingJob =
    #"{"jobs":[{"name":"fix","conversationId":"c1","status":"idle","#
    + #""question":{"id":"q1","text":"Which?","askedAt":1}}]}"#

  @MainActor private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @MainActor private func questionModel(
    answer: @escaping @Sendable (URLRequest) -> (Int, String)
  ) async -> AppModel {
    let model = AppModel(
      client: StubProtocol.client { request in
        switch request.url?.path {
        case "/v1/agents/a1/coding-jobs": (200, Self.waitingJob)
        case "/v1/agents/a1/coding-jobs/fix/answer": answer(request)
        default: (404, "")
        }
      })
    model.updateSelectedAgent("a1")
    let event = Message(
      id: "a1:1:0", role: "event", content: .string("Which?"), kind: JobQuestionEvent.messageKind,
      jobQuestion: JobQuestionEvent(id: "q1", kind: "coding", job: "fix"))
    model.applySnapshot(ChatSnapshot(messages: [event], agentId: "a1"))
    await waitFor { model.jobBoard.waitingQuestion("q1") != nil }
    return model
  }

  @MainActor @Test func answeringAJobQuestionSendsItAndRetiresTheQuestion() async throws {
    nonisolated(unsafe) var sent: [String: String]?
    let model = await questionModel { request in
      sent = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
      return (204, "")
    }
    let question = try #require(model.jobBoard.waitingQuestion("q1"))
    model.answerJobQuestion(question, job: "fix", reply: "Postgres")
    #expect(model.jobBoard.answers["q1"]?.sending == true)
    await waitFor { model.jobBoard.answers["q1"] == nil }
    #expect(sent == ["questionId": "q1", "text": "Postgres"])
    #expect(model.jobBoard.waitingQuestion("q1") == nil)
  }

  @MainActor @Test func aFailedAnswerKeepsWhatTheOwnerWrote() async throws {
    let model = await questionModel { _ in (500, #"{"error":"busy"}"#) }
    let question = try #require(model.jobBoard.waitingQuestion("q1"))
    model.jobBoard.answers["q1", default: JobAnswer()].text = "Postgres"
    model.answerJobQuestion(question, job: "fix", reply: "Postgres")
    await waitFor { model.jobBoard.answers["q1"]?.error.isEmpty == false }
    #expect(model.jobBoard.answers["q1"]?.text == "Postgres")
    #expect(model.jobBoard.answers["q1"]?.sending == false)
    #expect(model.jobBoard.waitingQuestion("q1") != nil)
  }

  @MainActor @Test func openingAJobLoadsItsHistory() async {
    let model = AppModel(
      client: StubProtocol.client { request in
        request.url?.path == "/v1/agents/a1/coding-jobs/fix/history"
          ? (200, #"{"messages":[{"id":"1","entryId":"e1","role":"user","content":"Fix it"}],"#
            + #""hasMore":false,"oldestEntryId":null}"#)
          : (404, "")
      })
    model.updateSelectedAgent("a1")
    model.openJob(.coding, "fix")
    await waitFor { model.jobHistory?.loaded == true }
    #expect(model.jobHistory?.messages.map(\.text) == ["Fix it"])
    #expect(model.jobPollDelay == .seconds(15))
  }

  @MainActor @Test func reopeningTheSameBotKeepsItsUnsentAnswer() async {
    let model = await questionModel { _ in (204, "") }
    model.jobBoard.select("a1")
    model.jobBoard.answers["q1", default: JobAnswer()].text = "Postgres"
    model.jobBoard.select("a1")
    #expect(model.jobBoard.answers["q1"]?.text == "Postgres")
    model.jobBoard.select("a2")
    #expect(model.jobBoard.answers.isEmpty)
  }

  @Test func jobCardsShowInChatAndTheirReportsStayBehindThem() {
    let started = Message(
      id: "1", role: "toolResult", toolName: "coding",
      toolDetails: .object(["name": .string("fix"), "status": .string("working")]))
    let report = Message(
      id: "2", role: "user", content: .string("Done"), origin: MessageOrigin(kind: "coding", name: "fix"))
    #expect(ChatRow.shownInChat(started))
    #expect(!ChatRow.shownInChat(report))
  }
}
