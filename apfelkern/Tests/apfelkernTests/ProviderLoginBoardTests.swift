import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func session(
  _ status: String, id: String = "l1", prompt: String = "null", failure: String = "null"
) -> StubResponse {
  let json = #"{"id":"\#(id)","provider":"openai","method":"oauth","status":"\#(status)","#
    + #""createdAt":1,"expiresAt":2,"prompt":\#(prompt),"events":[],"failure":\#(failure)}"#
  return StubResponse(body: Data(json.utf8))
}

private func started(prompt: String = "null") -> StubResponse {
  var response = session("pending", prompt: prompt)
  response.status = 202
  return response
}

private let question = #"{"id":"p1","type":"text","message":"Domain?"}"#

@MainActor private final class EventLog {
  var events: [String] = []
}

@MainActor
private func board(_ log: EventLog = EventLog()) -> ProviderLoginBoard {
  ProviderLoginBoard(pollInterval: .milliseconds(5)) { event in
    let name = switch event {
    case let .signedIn(provider): "signedIn:\(provider)"
    case .providersChanged: "providersChanged"
    case let .failed(message): "failed:\(message)"
    }
    log.events.append(name)
  }
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

/// A poll already on its way must land before the test's stub goes away.
@MainActor
private func stop(_ board: ProviderLoginBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(30))
}

@MainActor @Test func signInIsPendingUntilTheServerConfirms() async throws {
  let polls = Mutex(0)
  let log = EventLog()
  try await withClient(handler: { request in
    if request.httpMethod == "POST" { return started() }
    let count = polls.withLock { $0 += 1; return $0 }
    return session(count < 3 ? "pending" : "succeeded")
  }, test: { client in
    let board = board(log)
    board.start("openai", method: .oauth, client: client)
    #expect(board.requests == ["openai"])
    try await wait { board.logins["openai"] != nil }
    #expect(log.events.isEmpty)
    try await wait { board.logins.isEmpty }
    #expect(board.requests.isEmpty)
    #expect(board.outcomes.isEmpty)
    #expect(log.events == ["signedIn:openai"])
  })
}

@MainActor @Test func connectionErrorsKeepThePendingSignIn() async throws {
  let polls = Mutex(0)
  try await withClient(handler: { request in
    if request.httpMethod == "POST" { return started() }
    let count = polls.withLock { $0 += 1; return $0 }
    if count == 1 { throw URLError(.notConnectedToInternet) }
    return session("succeeded")
  }, test: { client in
    let board = board()
    board.start("openai", method: .oauth, client: client)
    try await wait { polls.withLock { $0 } > 0 }
    #expect(board.logins["openai"] != nil)
    try await wait { board.logins.isEmpty }
    #expect(board.outcomes.isEmpty)
  })
}

@MainActor @Test func signInThatEndsOnTheServerSaysWhy() async throws {
  let responses = Mutex([
    session("failed", failure: #"{"code":"provider_failure","message":"Denied"}"#),
    StubResponse(status: 410, body: Data(#"{"error":"gone"}"#.utf8))
  ])
  try await withClient(handler: { request in
    if request.httpMethod == "POST" { return started() }
    return responses.withLock { $0.removeFirst() }
  }, test: { client in
    let board = board()
    board.start("openai", method: .oauth, client: client)
    try await wait { board.outcomes["openai"] == "Denied" }
    #expect(board.logins.isEmpty)
    board.start("openai", method: .oauth, client: client)
    #expect(board.outcomes.isEmpty)
    try await wait { board.outcomes["openai"] == "This sign-in ended on the server. Start again." }
  })
}

@MainActor @Test func failedStartPicksUpARunningSignIn() async throws {
  let log = EventLog()
  try await withClient(handler: { _ in
    StubResponse(status: 409, body: Data(#"{"error":"already running"}"#.utf8))
  }, test: { client in
    let board = board(log)
    board.start("openai", method: .oauth, client: client)
    try await wait { board.outcomes["openai"] == "already running" }
    #expect(log.events == ["providersChanged"])
  })
}

@MainActor @Test func rejectedAnswerKeepsThePromptAndReportsTheError() async throws {
  let log = EventLog()
  try await withClient(handler: { request in
    switch request.httpMethod {
    case "POST" where request.url?.path.hasSuffix("/responses") == true:
      StubResponse(status: 409, body: Data(#"{"error":"answered"}"#.utf8))
    case "POST": started(prompt: question)
    default: session("pending", prompt: question)
    }
  }, test: { client in
    let board = board(log)
    board.start("openai", method: .oauth, client: client)
    try await wait { board.logins["openai"] != nil }
    let login = try #require(board.logins["openai"])
    board.answer(login, promptID: "p1", value: "github.com", client: client)
    try await wait { !log.events.isEmpty }
    #expect(log.events == ["failed:answered"])
    #expect(board.logins["openai"]?.prompt?.id == "p1")
    try await stop(board)
  })
}

@MainActor @Test func resetDropsAResponseFromTheOldConnection() async throws {
  let release = Mutex(false)
  try await withClient(handler: { _ in
    while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) }
    return started()
  }, test: { client in
    let board = board()
    board.start("openai", method: .oauth, client: client)
    board.reset()
    #expect(board.requests.isEmpty)
    release.withLock { $0 = true }
    try await Task.sleep(for: .milliseconds(50))
    #expect(board.logins.isEmpty)
  })
}

@MainActor @Test func resumePicksUpAnotherClientsSignIn() async throws {
  try await withClient(handler: { _ in session("pending", id: "l2") }, test: { client in
    let board = board()
    let status = ProviderStatus(provider: "openai", configured: false, activeLoginId: "l2")
    board.resume([status], client: client)
    try await wait { board.logins["openai"]?.id == "l2" }
    try await stop(board)
  })
}
