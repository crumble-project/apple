import Foundation
import Synchronization
import Testing
@testable import apfelkern

private let typed = "made-up-client-secret"

private func app(
  id: String = "a1", installed: Bool = false, secret: Bool = false, user: String? = nil, bots: [String] = []
) -> String {
  let ids = bots.map { #""\#($0)""# }.joined(separator: ",")
  let signedIn = user.map { #""\#($0)""# } ?? "null"
  return #"{"id":"\#(id)","slug":"scout","name":"scout","login":"scout[bot]","#
    + #""htmlUrl":"https://github.com/apps/scout","installUrl":"https://github.com/apps/scout/installations/new","#
    + #""account":"acme","installed":\#(installed),"#
    + #""clientSecret":{"configured":\#(secret),"passwordManager":null,"reference":null},"#
    + #""user":\#(signedIn),"botIds":[\#(ids)],"createdAt":"2026-11-05T10:00:00Z"}"#
}

private func list(_ apps: String...) -> StubResponse {
  StubResponse(body: Data(#"{"apps":[\#(apps.joined(separator: ","))]}"#.utf8))
}

private func one(_ json: String, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(body: Data(json.utf8), delay: delay)
}

private func refused(_ status: Int, _ message: String, delay: TimeInterval = 0) -> StubResponse {
  StubResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8), delay: delay)
}

private let noManagers = StubResponse(body: Data(#"{"passwordManagers":[]}"#.utf8))

private func isManagers(_ request: URLRequest) -> Bool {
  request.url?.path.hasSuffix("/password-managers") == true
}

private func isList(_ request: URLRequest) -> Bool {
  request.httpMethod == "GET" && request.url?.path.hasSuffix("/github-apps") == true
}

private func ends(_ request: URLRequest, _ suffix: String) -> Bool {
  request.url?.path.hasSuffix(suffix) == true
}

@MainActor
private func wait(_ done: () -> Bool) async throws {
  for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
  #expect(done())
}

/// The read that follows a write must land before the test's stub goes away.
@MainActor
private func stop(_ board: GitHubAppBoard) async throws {
  board.reset()
  try await Task.sleep(for: .milliseconds(300))
}

@MainActor
private func loaded(_ board: GitHubAppBoard, client: APIClient) async throws {
  board.refresh(client: client)
  try await wait { board.isLoaded }
}

private func sample(installed: Bool = false, secret: Bool = false, user: String? = nil) -> GitHubApp {
  GitHubApp(
    id: "a1", slug: "scout", name: "scout", login: "scout[bot]", htmlUrl: "https://github.com/apps/scout",
    installUrl: "https://github.com/apps/scout/installations/new", account: "acme", installed: installed,
    clientSecret: SecretStatus(configured: secret), user: user, botIds: ["b1"])
}

@Test func theDraftKeepsTheClientSecretOutOfItsDescriptionAndDump() {
  var draft = GitHubAppDraft(app: sample())
  draft.clientSecret.value = typed
  #expect(draft.canSaveClientSecret)
  var dumped = ""
  dump(draft, to: &dumped)
  #expect(!dumped.contains(typed))
  #expect(!String(describing: draft).contains(typed))
  draft.clearSecrets()
  #expect(!draft.canSaveClientSecret)
}

@Test func anAppDescribesItsInstallationAndWhoItActsAs() {
  #expect(sample().installationText == "Not installed on acme")
  #expect(sample(installed: true).installationText == "Installed on acme")
  #expect(sample().actsAsText == "scout[bot]")
  #expect(sample(user: "owner").actsAsText == "owner, marked as scout[bot]")
  #expect(sample(user: "owner").usedByText == "As owner, used by 1")
}

@Test func aNewAppNeedsANameAndStopsAtGitHubsLimit() {
  var draft = NewGitHubAppDraft()
  #expect(!draft.isReady)
  draft.name = "   "
  #expect(!draft.isReady)
  draft.name = String(repeating: "a", count: 40)
  #expect(draft.name.count == NewGitHubAppDraft.maxNameCharacters)
  #expect(draft.isReady)
}

@Test func theManifestPageEscapesTheManifestAndAnswersOnlyItsOwnPath() async throws {
  let manifest = GitHubAppManifest(
    url: "https://github.com/settings/apps/new?state=abc&x=1",
    manifest: #"{"name":"<scout>","url":"https://example.com/?a=1&b=2"}"#)
  let html = GitHubManifestPage.html(manifest)
  #expect(html.contains(#"action="https://github.com/settings/apps/new?state=abc&amp;x=1""#))
  #expect(html.contains("&quot;name&quot;:&quot;&lt;scout&gt;&quot;"))
  #expect(!html.contains(#""<scout>""#))

  let page = try await GitHubManifestPage.serve(manifest)
  defer { page.stop() }
  #expect(page.url.host() == "127.0.0.1")
  let session = URLSession(configuration: .ephemeral)
  let (body, answer) = try await session.data(from: page.url)
  #expect((answer as? HTTPURLResponse)?.statusCode == 200)
  #expect(String(data: body, encoding: .utf8) == html)
  var other = URLComponents(url: page.url, resolvingAgainstBaseURL: false)
  other?.path = "/favicon.ico"
  let (_, missing) = try await session.data(from: try #require(other?.url))
  #expect((missing as? HTTPURLResponse)?.statusCode == 404)
}

@MainActor @Test func assigningShowsAtOnceAndAFailureGivesTheSheetBack() async throws {
  let refuse = Mutex(true)
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return list(app()) }
    return refuse.withLock { $0 }
      ? refused(409, "b1 already uses another App", delay: 0.05)
      : one(app(bots: ["b1"]), delay: 0.05)
  }, test: { client in
    let board = GitHubAppBoard()
    try await loaded(board, client: client)
    board.edit(try #require(board.apps.first), client: client)
    board.draft?.botIDs = ["b1"]
    board.saveDraft(client: client)
    #expect(board.draft == nil)
    #expect(board.apps.first?.botIds == ["b1"])
    #expect(board.isUnconfirmed(try #require(board.apps.first)))
    try await wait { board.draft != nil }
    #expect(board.saveError.contains("another App"))
    #expect(board.draft?.botIDs == ["b1"])
    try await wait { board.apps.first?.botIds == [] }

    refuse.withLock { $0 = false }
    board.saveDraft(client: client)
    try await wait { board.apps.first.map { !board.isUnconfirmed($0) } == true }
    try await stop(board)
  })
}

@MainActor @Test func removingHidesAtOnceAndComesBackOnFailure() async throws {
  try await withClient(handler: { request in
    if isList(request) { return list(app()) }
    return refused(503, "GitHub is unavailable", delay: 0.05)
  }, test: { client in
    let board = GitHubAppBoard()
    try await loaded(board, client: client)
    board.remove(try #require(board.apps.first), client: client)
    #expect(board.apps.isEmpty)
    try await wait { board.errors["a1"] != nil }
    #expect(board.apps.count == 1)
    try await stop(board)
  })
}

@MainActor @Test func aClientSecretHoldsTheSheetUntilTheServerAnswers() async throws {
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return list(app()) }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return one(app(secret: true), delay: 0.05)
  }, test: { client in
    let board = GitHubAppBoard()
    try await loaded(board, client: client)
    board.edit(try #require(board.apps.first), client: client)
    board.draft?.clientSecret.value = typed
    board.saveClientSecret(client: client)
    #expect(board.isSaving)
    board.closeDraft()
    #expect(board.draft != nil)
    try await wait { !board.isSaving }
    #expect(board.draft?.app.clientSecret.configured == true)
    #expect(board.draft?.clientSecret.value.isEmpty == true)
    #expect(bodies.withLock { $0 } == [.object(["value": .string(typed)])])
    try await stop(board)
  })
}

@MainActor @Test func checkReportsWhyAnAppIsntInstalled() async throws {
  try await withClient(handler: { request in
    if isList(request) { return list(app()) }
    return refused(409, "Install scout on GitHub first", delay: 0.05)
  }, test: { client in
    let board = GitHubAppBoard()
    try await loaded(board, client: client)
    board.connect(try #require(board.apps.first), client: client)
    #expect(board.checking == ["a1"])
    try await wait { board.checking.isEmpty }
    #expect(board.errors["a1"] == "Install scout on GitHub first")
    #expect(board.apps.first?.installed == false)
    try await stop(board)
  })
}

@MainActor @Test func creatingSendsTheServersOriginAndClosesOnceTheAppAppears() async throws {
  let created = Mutex(false)
  let bodies = Mutex<[JSONValue]>([])
  try await withClient(handler: { request in
    if isList(request) { return created.withLock { $0 } ? list(app()) : list() }
    bodies.withLock { $0.append((try? requestJSON(request)) ?? .null) }
    return one(#"{"url":"https://github.com/settings/apps/new?state=s","manifest":"{}"}"#)
  }, test: { client in
    let board = GitHubAppBoard(pollInterval: .milliseconds(10))
    try await loaded(board, client: client)
    board.startNew()
    board.creation?.name = " scout "
    board.creation?.organization = "acme"
    board.createOnGitHub(client: client)
    #expect(board.isOpening)
    try await wait { board.trip != nil }
    #expect(board.trip?.step == .create)
    #expect(board.trip?.url.host() == "127.0.0.1")
    #expect(board.creation != nil)
    let body = try #require(bodies.withLock { $0.first })
    let origin = try #require(client.webSignInURL?.host())
    #expect(body == .object([
      "name": .string("scout"), "organization": .string("acme"), "origin": .string("https://\(origin)")
    ]))

    created.withLock { $0 = true }
    try await wait { board.trip == nil }
    #expect(board.creation == nil)
    #expect(board.apps.count == 1)
    try await stop(board)
  })
}

@MainActor @Test func closingTheBrowserWithoutANewAppExplainsWhatFinishesIt() async throws {
  try await withClient(handler: { request in
    if isList(request) { return list() }
    return one(#"{"url":"https://github.com/settings/apps/new?state=s","manifest":"{}"}"#)
  }, test: { client in
    let board = GitHubAppBoard(pollInterval: .seconds(60))
    try await loaded(board, client: client)
    board.startNew()
    board.creation?.name = "scout"
    board.createOnGitHub(client: client)
    try await wait { board.trip != nil }
    board.browserClosed(try #require(board.trip), client: client)
    try await wait { board.trip == nil }
    #expect(board.saveError.contains("web page"))
    #expect(board.creation?.name == "scout")
    try await stop(board)
  })
}

@MainActor @Test func installingKeepsWaitingThroughConflictsAndConnectsOnReturn() async throws {
  let installed = Mutex(false)
  try await withClient(handler: { request in
    let done = installed.withLock { $0 }
    if isList(request) { return list(app(installed: done)) }
    return done ? one(app(installed: true)) : refused(409, "Install scout on GitHub first")
  }, test: { client in
    let board = GitHubAppBoard(pollInterval: .milliseconds(10))
    try await loaded(board, client: client)
    board.install(try #require(board.apps.first), client: client)
    #expect(board.trip?.step == .install(appID: "a1"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(board.trip != nil)
    #expect(board.errors.isEmpty)
    installed.withLock { $0 = true }
    try await wait { board.trip == nil }
    #expect(board.apps.first?.installed == true)
    try await stop(board)
  })
}

@MainActor @Test func signingInWaitsForTheWebPageToFinishAndThenSigningOutConfirms() async throws {
  let signedIn = Mutex(false)
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    let user = signedIn.withLock { $0 } ? "owner" : nil
    if isList(request) { return list(app(secret: true, user: user)) }
    if ends(request, "/sign-in") { return one(#"{"url":"https://github.com/login/oauth/authorize?state=s"}"#) }
    if ends(request, "/user") { return one(app(secret: true), delay: 0.05) }
    return refused(500, "unexpected")
  }, test: { client in
    let board = GitHubAppBoard(pollInterval: .milliseconds(10))
    try await loaded(board, client: client)
    let app = try #require(board.apps.first)
    board.edit(app, client: client)
    board.signIn(app, client: client)
    try await wait { board.trip != nil }
    #expect(board.trip?.step == .signIn(appID: "a1"))
    signedIn.withLock { $0 = true }
    try await wait { board.trip == nil }
    #expect(board.draft?.app.user == "owner")

    board.signOut(try #require(board.apps.first), client: client)
    #expect(board.apps.first?.user == "owner")
    try await wait { board.apps.first?.user == nil }
    #expect(board.checking.isEmpty)
    try await stop(board)
  })
}

@MainActor @Test func aLateAnswerFromTheOldConnectionIsDropped() async throws {
  let late = StubResponse(body: Data(#"{"apps":[\#(app())]}"#.utf8), delay: 0.05)
  try await withClient(handler: { _ in late }, test: { client in
    let board = GitHubAppBoard()
    board.refresh(client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(120))
    #expect(!board.isLoaded)
    #expect(board.apps.isEmpty)
  })
}

@MainActor @Test func aTripsLateAnswerStaysOffTheNextConnection() async throws {
  try await withClient(handler: { request in
    if isManagers(request) { return noManagers }
    if isList(request) { return StubResponse(body: list(app(user: "owner")).body, delay: 0.05) }
    if ends(request, "/sign-in") { return one(#"{"url":"https://github.com/login/oauth/authorize?state=s"}"#) }
    return one(app(installed: true), delay: 0.05)
  }, test: { client in
    let board = GitHubAppBoard(pollInterval: .seconds(60))
    try await loaded(board, client: client)
    let app = try #require(board.apps.first)
    board.signIn(app, client: client)
    try await wait { board.trip != nil }
    board.browserClosed(try #require(board.trip), client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(120))
    #expect(!board.isLoaded)
    #expect(board.apps.isEmpty)

    try await loaded(board, client: client)
    board.install(try #require(board.apps.first), client: client)
    board.browserClosed(try #require(board.trip), client: client)
    board.reset()
    try await Task.sleep(for: .milliseconds(120))
    #expect(!board.isLoaded)
    #expect(board.apps.isEmpty)
  })
}

@MainActor @Test func aTripsReadFromBeforeARemovalDoesntBringTheAppBack() async throws {
  let removed = Mutex(false)
  let tripping = Mutex(false)
  let tripReads = Mutex(0)
  try await withClient(handler: { request in
    if ends(request, "/sign-in") { return one(#"{"url":"https://github.com/login/oauth/authorize?state=s"}"#) }
    if request.httpMethod == "DELETE" {
      removed.withLock { $0 = true }
      return StubResponse(status: 204, body: Data())
    }
    guard isList(request) else { return refused(500, "unexpected") }
    if removed.withLock({ $0 }) {
      return StubResponse(body: list(app(user: "owner")).body, delay: 0.3)
    }
    guard tripping.withLock({ $0 }) else { return list(app(), app(id: "a2")) }
    tripReads.withLock { $0 += 1 }
    return StubResponse(body: list(app(user: "owner"), app(id: "a2")).body, delay: 0.1)
  }, test: { client in
    let board = GitHubAppBoard(pollInterval: .milliseconds(5))
    try await loaded(board, client: client)
    let other = try #require(board.apps.first { $0.id == "a2" })
    board.signIn(try #require(board.apps.first), client: client)
    tripping.withLock { $0 = true }
    try await wait { tripReads.withLock { $0 } > 0 }
    board.remove(other, client: client)
    for _ in 0..<40 {
      #expect(!board.apps.contains { $0.id == "a2" })
      try await Task.sleep(for: .milliseconds(5))
    }
    try await wait { board.trip == nil && board.apps.first?.user == "owner" }
    #expect(board.apps.map(\.id) == ["a1"])
    try await stop(board)
  })
}
