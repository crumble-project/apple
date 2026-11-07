import Foundation
import Synchronization
import Testing
@testable import apfelkern

private func json(_ text: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(text.utf8), delay: delay)
}

private func passkey(_ id: String, name: String = "Laptop", synced: Bool = true) -> String {
  #"{"id":"\#(id)","name":"\#(name)","publicKey":"k","userId":"u","credentialID":"c","counter":0,"#
    + #""deviceType":"multiDevice","backedUp":\#(synced),"transports":"internal","#
    + #""createdAt":"2026-11-05T10:00:00.000Z","aaguid":null}"#
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

private func path(_ request: URLRequest) -> String {
  (request.url?.path ?? "").replacingOccurrences(of: "/prefix", with: "")
}

@MainActor @Test func passkeysLoadWithTheirNamesAndSyncState() async throws {
  try await withClient(handler: { request in
    #expect(path(request) == "/api/auth/passkey/list-user-passkeys")
    return json("[" + passkey("p1") + "]")
  }, test: { client in
    let board = PasskeyBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    #expect(board.passkeys.map(\.title) == ["Laptop"])
    #expect(board.passkeys.first?.detail.hasSuffix(" · Synced") == true)
  })
}

@MainActor @Test func anUnnamedPasskeyTakesTheGenericTitle() {
  #expect(Passkey(id: "p", createdAt: "2026-11-05T10:00:00.000Z").title == "Passkey")
  #expect(Passkey(id: "p", name: "", createdAt: "x").detail.isEmpty)
}

@MainActor @Test func theServerAnsweringNullListsNoPasskeys() async throws {
  try await withClient(handler: { _ in json("null") }, test: { client in
    let board = PasskeyBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    #expect(board.passkeys.isEmpty)
  })
}

@MainActor @Test func aRenameShowsAtOnceAndSurvivesAReadStartedBeforeIt() async throws {
  let sent = Mutex<[String]>([])
  try await withClient(handler: { request in
    if request.httpMethod == "GET" { return json("[" + passkey("p1") + "]") }
    sent.withLock { $0.append(path(request)) }
    return json(#"{"passkey":{}}"#, delay: 0.05)
  }, test: { client in
    let board = PasskeyBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.rename("p1", to: "  Phone  ", client: client, session: client.session)
    #expect(board.passkeys.first?.name == "Phone")
    #expect(board.isBusy("p1"))
    board.refresh(client: client)
    try await wait { !board.isBusy("p1") }
    #expect(board.passkeys.first?.name == "Phone")
    #expect(sent.withLock { $0 } == ["/api/auth/passkey/update-passkey"])
  })
}

@MainActor @Test func aFailedRenameComesBackWithTheServersReason() async throws {
  try await withClient(handler: { request in
    if request.httpMethod == "GET" { return json("[" + passkey("p1") + "]") }
    return json(#"{"message":"You are not allowed"}"#, status: 403)
  }, test: { client in
    let board = PasskeyBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.rename("p1", to: "Phone", client: client, session: client.session)
    try await wait { !board.isBusy("p1") }
    #expect(board.passkeys.first?.name == "Laptop")
    #expect(board.error != nil)
  })
}

@MainActor @Test func removingHidesAtOnceAndAFailureBringsThePasskeyBack() async throws {
  let fails = Mutex(true)
  try await withClient(handler: { request in
    if request.httpMethod == "GET" { return json("[" + passkey("p1") + "," + passkey("p2") + "]") }
    #expect(path(request) == "/api/auth/passkey/delete-passkey")
    return fails.withLock { $0 } ? json(#"{"message":"No"}"#, status: 500) : json(#"{"status":true}"#)
  }, test: { client in
    let board = PasskeyBoard()
    board.refresh(client: client)
    try await wait { board.isLoaded }
    board.remove("p1", client: client, session: client.session)
    #expect(board.passkeys.map(\.id) == ["p2"])
    try await wait { !board.isBusy("p1") }
    #expect(board.passkeys.map(\.id) == ["p1", "p2"])
    #expect(board.error != nil)
    fails.withLock { $0 = false }
    board.remove("p1", client: client, session: client.session)
    try await wait { !board.isBusy("p1") }
    #expect(board.passkeys.map(\.id) == ["p2"])
    #expect(board.error == nil)
  })
}

@MainActor @Test func aResetDropsAReadFromTheOldConnection() async throws {
  try await withClient(handler: { _ in json("[" + passkey("p1") + "]", delay: 0.05) }, test: { client in
    let board = PasskeyBoard()
    board.refresh(client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(120))
    #expect(board.passkeys.isEmpty)
    #expect(!board.isLoaded)
  })
}

@MainActor @Test func aLaterReadClearsAnEarlierFailure() async throws {
  let calls = Mutex(0)
  try await withClient(handler: { _ in
    let call = calls.withLock { count in
      count += 1
      return count
    }
    return call == 1 ? json(#"{"error":"offline"}"#, status: 500) : json("[" + passkey("p1") + "]")
  }, test: { client in
    let board = PasskeyBoard()
    board.refresh(client: client)
    try await wait { board.error != nil }
    board.refresh(client: client)
    try await wait { board.isLoaded }
    #expect(board.error == nil)
  })
}
