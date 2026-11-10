import apfelkern
import Foundation
import Synchronization
import Testing

@testable import Crumble

extension APIClientTests {
  private static func saved(_ id: String, _ status: String) -> String {
    #"{"id":"\#(id)","agentId":"a1","number":"+4930123456","callee":"Dr. Weber","goal":"Book a visit","#
      + #""opening":"Hello, this is Bot.","status":"\#(status)","callId":"c1","conversationId":"v1","#
      + #""outcome":null,"error":null,"requestedAt":"2026-11-05T10:00:00Z","decidedAt":null,"endedAt":null}"#
  }

  private static let spoken =
    #"{"messages":[{"id":"1","entryId":"e1","role":"user","content":"Hello?"},"#
    + #"{"id":"2","entryId":"e2","role":"assistant","content":"Good day.","#
    + #""blocks":[{"type":"text","text":"Good day."}]}],"#
    + #""hasMore":false,"oldestEntryId":null}"#

  private static func callRequest(_ id: String, _ status: String = "calling") throws -> CallRequest {
    let details = try JSONDecoder().decode(JSONValue.self, from: Data(saved(id, status).utf8))
    let message = Message(
      id: "m-\(id)", role: "toolResult", toolName: CallRequest.toolName, toolDetails: details)
    return try #require(CallRequest(message: message))
  }

  @MainActor private func waitForCall(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @MainActor private func callModel(
    _ handler: @escaping @Sendable (URLRequest) -> (Int, String)
  ) -> AppModel {
    let model = AppModel(client: StubProtocol.client(handler))
    model.updateSelectedAgent("a1")
    model.callRequestBoard.select("a1")
    return model
  }

  @MainActor @Test func openingACallLoadsItsTranscript() async throws {
    let model = callModel { request in
      request.url?.path == "/v1/agents/a1/call-requests/r1/transcript" ? (200, Self.spoken) : (404, "")
    }
    model.openCall(try Self.callRequest("r1", "ended"))
    await model.watchOpenCall()
    #expect(model.openedCall?.loaded == true)
    #expect(model.openedCall?.lines.map(\.text) == ["Hello?", "Good day."])
    #expect(model.openedCall?.lines.map(\.speaker) == [.callee, .bot])
  }

  @MainActor @Test func aFailedTranscriptLoadIsMarkedAndKeepsWhatWasLoaded() async throws {
    let fail = Atomic(false)
    let model = callModel { _ in fail.load(ordering: .acquiring) ? (500, "") : (200, Self.spoken) }
    model.openCall(try Self.callRequest("r1", "ended"))
    await model.loadCallTranscript()
    fail.store(true, ordering: .releasing)
    await model.loadCallTranscript()
    #expect(model.openedCall?.failed == true)
    #expect(model.openedCall?.lines.count == 2)
  }

  @MainActor @Test func theTranscriptReloadsWhileCallingAndStopsAfterItEnds() async throws {
    let ended = Atomic(false)
    let loads = Atomic(0)
    let model = callModel { request in
      if request.url?.path == "/v1/agents/a1/call-requests" {
        return (200, "[" + Self.saved("r1", ended.load(ordering: .acquiring) ? "ended" : "calling") + "]")
      }
      loads.add(1, ordering: .relaxed)
      return (200, Self.spoken)
    }
    let client = try #require(model.client)
    model.callRequestBoard.refresh(client: client)
    await waitForCall { model.callRequestBoard.requests.first?.status == .calling }
    model.openCall(try Self.callRequest("r1", "calling"))
    let watching = Task { await model.watchOpenCall(every: .milliseconds(10)) }
    await waitForCall { loads.load(ordering: .relaxed) >= 3 }
    #expect(loads.load(ordering: .relaxed) >= 3)
    ended.store(true, ordering: .releasing)
    model.callRequestBoard.refresh(client: client)
    await watching.value
    let final = loads.load(ordering: .relaxed)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(loads.load(ordering: .relaxed) == final)
    #expect(model.openCallRequest?.status == .ended)
  }

  @MainActor @Test func aLateTranscriptForAnotherCallIsDropped() async throws {
    let model = callModel { request in
      if request.url?.path == "/v1/agents/a1/call-requests/r1/transcript" {
        Thread.sleep(forTimeInterval: 0.2)
        return (200, Self.spoken)
      }
      return (200, #"{"messages":[],"hasMore":false,"oldestEntryId":null}"#)
    }
    model.openCall(try Self.callRequest("r1"))
    let late = Task { await model.loadCallTranscript() }
    try? await Task.sleep(for: .milliseconds(30))
    model.openCall(try Self.callRequest("r2"))
    await model.loadCallTranscript()
    await late.value
    #expect(model.openedCall?.id == "r2")
    #expect(model.openedCall?.lines.isEmpty == true)
    #expect(model.openedCall?.loaded == true)
  }

  @MainActor @Test func aTranscriptForABotThatWasLeftIsDropped() async throws {
    let model = callModel { _ in
      Thread.sleep(forTimeInterval: 0.1)
      return (200, Self.spoken)
    }
    model.openCall(try Self.callRequest("r1"))
    let late = Task { await model.loadCallTranscript() }
    try? await Task.sleep(for: .milliseconds(20))
    model.updateSelectedAgent("a2")
    await late.value
    #expect(model.openedCall?.loaded == false)
    #expect(model.openedCall?.lines.isEmpty == true)
  }
}
