import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let inviteLink = "https://example.invalid/connect?invite=made-up-invite"

private func user(_ id: String, role: String = "user") -> String {
  #"{"id":"\#(id)","email":"\#(id)@example.com","name":"","role":"\#(role)","createdAt":"2026-11-05T10:00:00.000Z"}"#
}

private func json(_ text: String, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(body: Data(text.utf8), delay: delay)
}

private func refused(_ status: Int, _ message: String, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8), delay: delay)
}

private func settings(signUpOpen: Bool = true, image: String = "null") -> StubResponse {
  json(#"{"signUpOpen":\#(signUpOpen),"workspaceCpus":2,"workspaceMemoryMib":4096,"codingImage":\#(image),"#
    + #""questionGraceMinutes":15}"#)
}

/// A server with an admin `me`, a regular user `u2`, and one invite. `writes` answers everything else.
private func server(
  role: String = "admin", read: @escaping @Sendable (String) -> Void = { _ in },
  writes: @escaping @Sendable (URLRequest) -> StubResponse = { _ in StubResponse(status: 204, body: Data()) }
) -> ContractURLProtocol.Handler {
  { request in
    let path = request.url?.path ?? ""
    guard request.httpMethod == "GET" else { return writes(request) }
    read(path)
    if path.hasSuffix("/api/auth/get-session") {
      return json(#"{"session":{"token":"made-up"},"user":{"id":"me","name":"Me","email":"me@example.com","role":"\#(role)"}}"#)
    }
    if path.hasSuffix("/admin/users") { return json(#"{"users":[\#(user("me", role: "admin")),\#(user("u2"))]}"#) }
    if path.hasSuffix("/admin/invites") {
      return json(#"{"invites":[{"id":"i1","createdAt":"2026-11-05T10:00:00.000Z"}]}"#)
    }
    if path.hasSuffix("/admin/settings") { return settings() }
    return json(#"{"workspaces":[{"userId":"u2","agentId":"a1"}]}"#)
  }
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

@MainActor
private func loaded(_ board: AdminBoard, client: APIClient) async throws {
  board.refresh(client: client)
  try await wait { board.isLoaded }
}

/// The read that follows a write must land before the test's stub goes away.
@MainActor
private func stop(_ board: AdminBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(300))
}

@MainActor @Test func aRegularAccountReadsNoAdminData() async throws {
  let reads = Mutex<[String]>([])
  let handler = server(role: "user", read: { path in reads.withLock { $0.append(path) } })
  try await withClient(handler: handler, test: { client in
    let board = AdminBoard()
    board.refresh(client: client)
    try await wait { board.isAccountLoaded }
    #expect(!board.isAdmin)
    #expect(board.users.isEmpty)
    #expect(reads.withLock { $0.count } == 1)
    try await stop(board)
  })
}

@MainActor @Test func anAccountReadThatFindsAnAdminLoadsTheAdminData() async throws {
  try await withClient(handler: server(), test: { client in
    let board = AdminBoard()
    board.loadAccount(client: client)
    try await wait { board.isLoaded }
    #expect(board.users.count == 2)
    try await stop(board)
  })
}

@MainActor @Test func aFailedRoleReadStillEndsAKnownAdminsWait() async throws {
  let sessions = Mutex(0)
  let working = server()
  try await withClient(handler: { request in
    let isSession = request.url?.path.hasSuffix("/api/auth/get-session") == true
    let read = sessions.withLock { value in
      if isSession { value += 1 }
      return value
    }
    return read > 1 ? refused(503, "Server is down") : try working(request)
  }, test: { client in
    let board = AdminBoard()
    board.loadAccount(client: client)
    try await wait { board.isLoaded }
    #expect(board.isAdmin)
    #expect(board.usersError == "Server is down")
    #expect(board.settingsError == "Server is down")
    try await stop(board)
  })
}

@MainActor @Test func anUnknownSessionIsNotAnAdmin() async throws {
  try await withClient(handler: { _ in json("null") }, test: { client in
    let account = try await client.serverAccount()
    #expect(account == nil)
  })
}

@MainActor @Test func anAdminCannotChangeOrRemoveThemselves() async throws {
  let writes = Mutex(0)
  try await withClient(handler: server(writes: { _ in
    writes.withLock { $0 += 1 }
    return refused(500, "unexpected")
  }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    let own = try #require(board.users.first { $0.id == "me" })
    let other = try #require(board.users.first { $0.id == "u2" })
    #expect(!board.canManage(own))
    #expect(board.canManage(other))
    board.setRole(.user, for: own, client: client)
    board.remove(own, client: client)
    #expect(board.users.count == 2)
    #expect(board.users.first { $0.id == "me" }?.role == .admin)
    try await Task.sleep(for: .milliseconds(50))
    #expect(writes.withLock { $0 } == 0)
    try await stop(board)
  })
}

@MainActor @Test func aRoleChangeShowsAtOnceAndComesBackWhenRefused() async throws {
  try await withClient(handler: server(writes: { _ in
    refused(409, "The server needs at least one admin", delay: 0.05)
  }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    let other = try #require(board.users.first { $0.id == "u2" })
    board.setRole(.admin, for: other, client: client)
    #expect(board.users.first { $0.id == "u2" }?.role == .admin)
    #expect(board.isUnconfirmed(other))
    try await wait { board.errors["u2"] != nil }
    #expect(board.errors["u2"]?.contains("at least one admin") == true)
    #expect(board.users.first { $0.id == "u2" }?.role == .user)
    try await stop(board)
  })
}

@MainActor @Test func removingLeavesAtOnceAndComesBackOnFailure() async throws {
  try await withClient(handler: server(writes: { _ in refused(500, "No", delay: 0.05) }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    let other = try #require(board.users.first { $0.id == "u2" })
    board.remove(other, client: client)
    #expect(!board.users.contains(other))
    try await wait { board.errors["u2"] != nil }
    #expect(board.users.contains(other))
    try await stop(board)
  })
}

@MainActor @Test func aReadThatPredatesARemovalCannotBringTheUserBack() async throws {
  try await withClient(handler: server(writes: { _ in StubResponse(status: 204, body: Data(), delay: 0.05) }),
    test: { client in
      let board = AdminBoard()
      try await loaded(board, client: client)
      let other = try #require(board.users.first { $0.id == "u2" })
      board.remove(other, client: client)
      board.refresh(client: client)
      try await Task.sleep(for: .milliseconds(30))
      #expect(!board.users.contains(other))
      try await stop(board)
    })
}

@MainActor @Test func anInviteLinkShowsOnceAndStaysOutOfDescriptions() async throws {
  let minted = Mutex(0)
  try await withClient(handler: server(writes: { _ in
    minted.withLock { $0 += 1 }
    return json(#"{"id":"i2","createdAt":"2026-11-05T10:00:00.000Z","url":"\#(inviteLink)"}"#, delay: 0.02)
  }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    board.createInvite(client: client)
    board.createInvite(client: client)
    #expect(board.inviteSheet?.isPending == true)
    try await wait { board.inviteSheet?.link != nil }
    #expect(minted.withLock { $0 } == 1)
    let sheet = try #require(board.inviteSheet)
    #expect(sheet.link == inviteLink)
    var dumped = ""
    dump(sheet, to: &dumped)
    #expect(!dumped.contains("made-up-invite"))
    #expect(!"\(sheet)".contains("made-up-invite"))
    #expect(!String(reflecting: sheet).contains("made-up-invite"))
    board.closeInviteSheet()
    try await Task.sleep(for: .milliseconds(30))
    #expect(minted.withLock { $0 } == 1)
    #expect(board.inviteSheet == nil)
    try await stop(board)
  })
}

@MainActor @Test func aLinkAnsweredAfterTheSheetClosedIsDropped() async throws {
  try await withClient(handler: server(writes: { _ in
    json(#"{"id":"i2","createdAt":"2026-11-05T10:00:00.000Z","url":"\#(inviteLink)"}"#, delay: 0.05)
  }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    board.createInvite(client: client)
    board.closeInviteSheet()
    try await Task.sleep(for: .milliseconds(120))
    #expect(board.inviteSheet == nil)
    try await stop(board)
  })
}

@MainActor @Test func revokingLeavesAtOnceAndComesBackOnFailure() async throws {
  try await withClient(handler: server(writes: { _ in refused(404, "No such invite", delay: 0.05) }),
    test: { client in
      let board = AdminBoard()
      try await loaded(board, client: client)
      let invite = try #require(board.invites.first)
      board.revoke(invite, client: client)
      #expect(board.invites.isEmpty)
      try await wait { board.errors["i1"] != nil }
      #expect(board.invites == [invite])
      try await stop(board)
    })
}

@MainActor @Test func signUpShowsAtOnceAndComesBackOnFailure() async throws {
  try await withClient(handler: server(writes: { _ in refused(500, "No", delay: 0.05) }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    board.setSignUpOpen(false, client: client)
    #expect(board.settings?.signUpOpen == false)
    #expect(board.isSavingSignUp)
    try await wait { board.signUpError != nil }
    #expect(board.settings?.signUpOpen == true)
    board.refresh(client: client)
    try await Task.sleep(for: .milliseconds(50))
    #expect(board.signUpError != nil)
    try await stop(board)
  })
}

@MainActor @Test func aFailedSettingsSaveReopensTheSheetWithWhatWasTyped() async throws {
  try await withClient(handler: server(writes: { _ in refused(400, "Invalid", delay: 0.05) }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    board.edit(.grace)
    board.draft?.grace = "30"
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(board.settings?.questionGraceMinutes == 30)
    try await wait { board.draft != nil }
    #expect(board.draft?.grace == "30")
    #expect(board.saveError == "Invalid")
    #expect(board.settings?.questionGraceMinutes == 15)
    try await stop(board)
  })
}

@MainActor @Test func clearingTheCodingImageSendsNullAndOnlyThatField() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: server(writes: { request in
    if let body = try? requestJSON(request) { bodies.withLock { $0.append(body) } }
    return settings()
  }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    board.edit(.image)
    board.draft?.image = "   "
    board.saveDraft(client: client)
    try await wait { !bodies.withLock(\.isEmpty) }
    #expect(bodies.withLock { $0 } == [.object(["codingImage": .null])])
    try await stop(board)
  })
}

@MainActor @Test func resetDropsAnInviteLinkAndTheAccount() async throws {
  try await withClient(handler: server(writes: { _ in
    json(#"{"id":"i2","createdAt":"2026-11-05T10:00:00.000Z","url":"\#(inviteLink)"}"#)
  }), test: { client in
    let board = AdminBoard()
    try await loaded(board, client: client)
    board.createInvite(client: client)
    try await wait { board.inviteSheet?.link != nil }
    board.reset()
    #expect(board.inviteSheet == nil)
    #expect(!board.isAdmin)
    try await stop(board)
  })
}

@Test func settingsDraftsStopAtTheServersLimits() {
  let saved = ServerSettings(
    signUpOpen: true, workspaceCpus: 2, workspaceMemoryMib: 1536, codingImage: nil, questionGraceMinutes: 15)
  var draft = ServerSettingsDraft(field: .size, settings: saved)
  #expect(draft.memory == "1.5")
  #expect(draft.patch?.workspaceMemoryMib == 1536)
  draft.memory = "1,5"
  #expect(draft.patch?.workspaceMemoryMib == 1536)
  for bad in ["", "0.1", "1000", "inf", "nan"] {
    draft.memory = bad
    #expect(!draft.isReady)
  }
  draft.memory = "4"
  draft.cpus = "65"
  #expect(!draft.isReady)

  var image = ServerSettingsDraft(field: .image, settings: saved)
  image.image = "ghcr.io/owner/image:tag"
  #expect(image.isReady)
  image.image = "Upper/case"
  #expect(!image.isReady)
  image.image = "has space"
  #expect(!image.isReady)

  var grace = ServerSettingsDraft(field: .grace, settings: saved)
  grace.grace = "1441"
  #expect(!grace.isReady)
  grace.grace = "0"
  #expect(grace.isReady)
}

@Test func capabilityNotesNameOnlyWhatTheServerLacks() {
  #expect(ServerCapabilities(coding: true, desktop: true).missingNotes.isEmpty)
  #expect(ServerCapabilities(coding: true, desktop: false).missingNotes
    == ["Desktop jobs need CRUMBLE_WORKSPACE_DESKTOP_IMAGE on the server."])
}
