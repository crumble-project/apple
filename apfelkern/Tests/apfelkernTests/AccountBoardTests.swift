import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let token = "made-up-invite"

private func refused(_ status: Int, _ message: String) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"code":"REFUSED","message":"\#(message)"}"#.utf8))
}

private let signedUp = StubResponse(body: Data(#"{"token":"made-up-session","user":{"id":"u1"}}"#.utf8))

@MainActor
private func filled(mode: AccountBoard.Mode = .signUp) -> AccountBoard {
  let board = AccountBoard()
  board.mode = mode
  board.name = " Ada "
  board.email = " ada@example.com "
  board.password = " made up "
  return board
}

@Test func anInviteLinkGivesItsServerAndToken() throws {
  let link = try #require(InviteLink(" https://crumble.example.com:8443/connect?invite=\(token)\n"))
  #expect(link.serverURL == "https://crumble.example.com:8443")
  #expect(link.token == token)
}

@Test(arguments: [
  "https://crumble.example.com", "https://crumble.example.com/connect",
  "https://crumble.example.com/connect?invite=", "https://crumble.example.com/other?invite=x",
  "ftp://crumble.example.com/connect?invite=x", "not a link"
])
func otherTextIsNotAnInviteLink(text: String) {
  #expect(InviteLink(text) == nil)
}

@Test func anInviteLinkKeepsItsTokenOutOfDescriptions() throws {
  let link = try #require(InviteLink("https://crumble.example.com/connect?invite=\(token)"))
  var dumped = ""
  dump(link, to: &dumped)
  #expect(!String(describing: link).contains(token))
  #expect(!dumped.contains(token))
}

@MainActor @Test func pastingAnInviteLinkLeavesTheServerAndOpensSignUp() {
  let board = AccountBoard()
  var serverURL = "https://crumble.example.com/connect?invite=\(token)"
  board.takeInvite(from: &serverURL)
  #expect(serverURL == "https://crumble.example.com")
  #expect(board.invite?.token == token)
  #expect(board.mode == .signUp)

  var typing = "https://crumble.example"
  board.takeInvite(from: &typing)
  #expect(typing == "https://crumble.example")
  #expect(board.invite?.token == token)
}

@MainActor @Test func signUpNeedsANameButSignInDoesNot() {
  let board = filled()
  board.name = "  "
  #expect(!board.isComplete)
  board.mode = .signIn
  #expect(board.isComplete)
  board.password = ""
  #expect(!board.isComplete)
}

@MainActor @Test func signUpSendsTheInviteInItsHeaderAndKeepsThePasswordExact() async throws {
  let seen = Mutex<URLRequest?>(nil)
  try await withClient(handler: { request in
    seen.withLock { $0 = request }
    return signedUp
  }, test: { client in
    let board = filled()
    var link = client.baseURL + "/connect?invite=" + token
    board.takeInvite(from: &link)
    let session = try await board.createSession(baseURL: link, session: client.session)
    #expect(session == "made-up-session")
    #expect(board.invite == nil)
    #expect(board.mode == .signIn)
  })
  let request = try #require(seen.withLock { $0 })
  #expect(request.url?.path.hasSuffix("/api/auth/sign-up/email") == true)
  #expect(request.value(forHTTPHeaderField: "x-crumble-invite") == token)
  #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  let body = try requestJSON(request)
  #expect(body == .object([
    "name": .string("Ada"), "email": .string("ada@example.com"), "password": .string(" made up ")
  ]))
}

@MainActor @Test func aRefusedSignUpShowsTheServersReasonAndKeepsTheForm() async throws {
  try await withClient(handler: { _ in
    refused(403, "Sign-up is closed. Ask an admin for an invite link.")
  }, test: { client in
    let board = filled()
    await #expect(throws: AccountSignInError.rejected("Sign-up is closed. Ask an admin for an invite link.")) {
      try await board.createSession(baseURL: client.baseURL, session: client.session)
    }
    #expect(board.mode == .signUp)
    #expect(board.password == " made up ")
  })
}

@MainActor @Test func aWrongPasswordStaysInvalidCredentials() async throws {
  try await withClient(handler: { _ in refused(401, "Invalid email or password") }, test: { client in
    let board = filled(mode: .signIn)
    await #expect(throws: AccountSignInError.invalidCredentials) {
      try await board.createSession(baseURL: client.baseURL, session: client.session)
    }
  })
}

@MainActor @Test func finishingDropsThePasswordAndTheInvite() {
  let board = filled()
  var link = "https://crumble.example.com/connect?invite=\(token)"
  board.takeInvite(from: &link)
  board.finish()
  #expect(board.password.isEmpty)
  #expect(board.name.isEmpty)
  #expect(board.invite == nil)
  #expect(board.mode == .signIn)
}

@MainActor @Test func signingOutReleasesFirstAndEndsTheSessionItHolds() async throws {
  let order = Mutex<[String]>([])
  try await withClient(token: "made-up-session", handler: { request in
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path.hasSuffix("/api/auth/sign-out") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer made-up-session")
    order.withLock { $0.append("server") }
    return StubResponse(body: Data(#"{"success":true}"#.utf8))
  }, test: { client in
    let board = filled(mode: .signIn)
    let outcome = await board.signOut(
      client: client, release: { order.withLock { $0.append("release") } }, session: client.session)
    #expect(outcome == .confirmed)
    #expect(!board.isSigningOut)
    #expect(board.email.isEmpty)
    #expect(board.password.isEmpty)
  })
  #expect(order.withLock { $0 } == ["release", "server"])
}

@MainActor @Test func aSessionTheServerAlreadyEndedCountsAsSignedOut() async throws {
  try await withClient(handler: { _ in refused(401, "Unauthorized") }, test: { client in
    #expect(await AccountBoard().signOut(client: client, session: client.session) == .confirmed)
  })
}

@MainActor @Test func aServerThatCantConfirmStillSignsOutThisDevice() async throws {
  try await withClient(handler: { _ in refused(503, "Down") }, test: { client in
    #expect(await AccountBoard().signOut(client: client, session: client.session) == .thisDeviceOnly)
  })
}

@MainActor @Test func anUnknownSessionReadsAsEnded() async throws {
  try await withClient(handler: { _ in StubResponse(body: Data("null".utf8)) }, test: { client in
    let board = AdminBoard()
    #expect(!board.sessionEnded)
    board.loadAccount(client: client)
    for _ in 0..<400 where !board.isAccountLoaded { try await Task.sleep(for: .milliseconds(5)) }
    #expect(board.sessionEnded)
  })
}
