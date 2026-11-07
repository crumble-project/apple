import Foundation
import Observation

/// The owner's GitHub Apps and the sheets that create and edit one. Assigning bots and removing apply
/// at once; a failed assignment gives the sheet back. Everything that depends on GitHub shows pending
/// until the server confirms it. Results that return after the connection changed are dropped.
///
/// GitHub sends the browser back to the server's web page, never to the app, so that page finishes
/// creating an App and signing in. A trip therefore watches the server for the result.
@MainActor @Observable
public final class GitHubAppBoard {
  private var loaded: [GitHubApp] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  private var reads = 0
  /// Reads up to this one are ignored: they may predate a newer read or a write.
  private var settledRead = 0
  /// Hidden from the list until the server answers, so a read can't bring them back.
  private var removing: Set<String> = []
  /// The bots to show for an App until the server answers, so a read can't take them away.
  private var assigning: [String: Set<String>] = [:]
  /// Why the last action on an App failed, by App.
  public private(set) var errors: [String: String] = [:]
  /// Apps with a request on its way to GitHub.
  public private(set) var checking: Set<String> = []

  /// The New GitHub App sheet.
  public var creation: NewGitHubAppDraft?
  /// The sheet for one App. Only here, in a save in flight, and in `returned` does a typed secret live.
  public var draft: GitHubAppDraft?
  /// Failed assignments waiting for the open sheet to close.
  private var returned: [(draft: GitHubAppDraft, error: String)] = []
  /// A client secret is with the server, so the sheet can't close until it answers.
  public private(set) var isSaving = false
  /// The server is preparing a trip that hasn't left yet.
  public private(set) var isOpening = false
  public private(set) var saveError = ""
  public private(set) var connectedManagers: [PasswordManager] = []

  /// The browser step in progress. An app opens `trip.url` when this changes.
  public private(set) var trip: GitHubTrip?
  private var page: GitHubManifestPage?
  private var knownApps: Set<String> = []
  @ObservationIgnored private var following: Task<Void, Never>?
  private var scope = 0
  private let pollInterval: Duration

  public init(pollInterval: Duration = .seconds(3)) {
    self.pollInterval = pollInterval
  }

  public func reset() {
    scope += 1
    leave()
    loaded = []
    isLoaded = false
    readError = nil
    reads = 0
    settledRead = 0
    removing = []
    assigning = [:]
    errors = [:]
    checking = []
    returned = []
    isSaving = false
    isOpening = false
    creation = nil
    closeDraft()
    connectedManagers = []
  }

  public var apps: [GitHubApp] {
    loaded.filter { !removing.contains($0.id) }.map { app in
      var shown = app
      if let botIDs = assigning[app.id] { shown.botIds = botIDs.sorted() }
      return shown
    }
  }

  /// Its row shows bots the owner assigned, and the server hasn't answered yet.
  public func isUnconfirmed(_ app: GitHubApp) -> Bool { assigning[app.id] != nil }

  public func refresh(client: APIClient) {
    let version = scope
    reads += 1
    let read = reads
    Task {
      do {
        let apps = try await client.gitHubApps()
        guard scope == version, read > settledRead else { return }
        settledRead = read
        take(apps)
        readError = nil
      } catch {
        guard scope == version, read > settledRead else { return }
        readError = friendlyError(error)
      }
    }
  }

  // MARK: Sheets

  public func startNew() {
    guard creation == nil, draft == nil else { return }
    saveError = ""
    creation = NewGitHubAppDraft()
  }

  public func closeNew() {
    guard !isOpening else { return }
    if trip?.step == .create { leave() }
    creation = nil
    saveError = ""
  }

  /// Never replaces an open sheet: it may hold a typed secret, or an assignment that came back.
  public func edit(_ app: GitHubApp, client: APIClient) {
    guard draft == nil, creation == nil, !isUnconfirmed(app) else { return }
    draft = GitHubAppDraft(app: app)
    saveError = ""
    let version = scope
    Task {
      guard let managers = try? await client.passwordManagers(), scope == version else { return }
      connectedManagers = managers.filter(\.connected)
    }
  }

  public func closeDraft() {
    guard !isSaving else { return }
    draft?.clearSecrets()
    draft = nil
    saveError = ""
    if !returned.isEmpty {
      let next = returned.removeFirst()
      draft = next.draft
      saveError = next.error
    }
  }

  // MARK: Saving

  public var canSave: Bool {
    guard let draft, !isSaving else { return false }
    return !isUnconfirmed(draft.app)
  }

  public func saveDraft(client: APIClient) {
    guard canSave, let draft else { return }
    guard draft.changesBots else {
      closeDraft()
      return
    }
    let id = draft.app.id
    let version = scope
    assigning[id] = draft.botIDs
    closeDraft()
    Task {
      do {
        let assigned = try await client.setGitHubAppBots(appID: id, botIDs: draft.botIDs)
        guard scope == version else { return }
        store(assigned)
      } catch {
        guard scope == version else { return }
        settledRead = reads
        giveBack(draft, error: friendlyError(error))
      }
      assigning[id] = nil
      refresh(client: client)
    }
  }

  private func giveBack(_ failed: GitHubAppDraft, error: String) {
    guard draft == nil else {
      returned.append((failed, error))
      return
    }
    draft = failed
    saveError = error
  }

  public func saveClientSecret(client: APIClient) {
    guard let draft, !isSaving, let input = draft.clientSecret.changedInput else { return }
    let id = draft.app.id
    let version = scope
    saveError = ""
    isSaving = true
    Task {
      do {
        let saved = try await client.setGitHubAppClientSecret(input, appID: id)
        guard scope == version else { return }
        store(saved)
        if self.draft?.app.id == id { self.draft?.clientSecretSaved(saved) }
      } catch {
        guard scope == version else { return }
        saveError = friendlyError(error)
      }
      isSaving = false
    }
  }

  private func take(_ apps: [GitHubApp]) {
    loaded = apps
    isLoaded = true
    if let current = draft?.app.id, let app = apps.first(where: { $0.id == current }) { draft?.app = app }
  }

  private func store(_ app: GitHubApp) {
    settledRead = reads
    isLoaded = true
    if let index = loaded.firstIndex(where: { $0.id == app.id }) {
      loaded[index] = app
    } else {
      loaded.append(app)
    }
    if draft?.app.id == app.id { draft?.app = app }
  }

  // MARK: Asking GitHub

  /// Asks the server whether the App is installed yet.
  public func connect(_ app: GitHubApp, client: APIClient) {
    ask(app) { try await client.connectGitHubApp(appID: app.id) }
  }

  public func signOut(_ app: GitHubApp, client: APIClient) {
    ask(app) { try await client.signOutGitHubApp(appID: app.id) }
  }

  private func ask(_ app: GitHubApp, _ work: @escaping @MainActor () async throws -> GitHubApp) {
    guard checking.insert(app.id).inserted else { return }
    errors[app.id] = nil
    let version = scope
    Task {
      do {
        let answer = try await work()
        guard scope == version else { return }
        store(answer)
      } catch {
        guard scope == version else { return }
        errors[app.id] = friendlyError(error)
      }
      checking.remove(app.id)
    }
  }

  // MARK: Removing

  public func remove(_ app: GitHubApp, client: APIClient) {
    guard !isUnconfirmed(app), removing.insert(app.id).inserted else { return }
    errors[app.id] = nil
    let version = scope
    Task {
      do {
        try await client.deleteGitHubApp(appID: app.id)
        guard scope == version else { return }
        loaded.removeAll { $0.id == app.id }
      } catch {
        guard scope == version else { return }
        errors[app.id] = friendlyError(error)
      }
      settledRead = reads
      removing.remove(app.id)
      refresh(client: client)
    }
  }

  // MARK: Browser trips

  public var canLeave: Bool { trip == nil && !isOpening }

  public func createOnGitHub(client: APIClient) {
    guard canLeave, let creation, creation.isReady else { return }
    saveError = ""
    isOpening = true
    let version = scope
    Task {
      do {
        let known = Set(try await client.gitHubApps().map(\.id))
        let manifest = try await client.createGitHubAppManifest(
          name: creation.trimmedName, organization: creation.trimmedOrganization)
        guard scope == version else { return }
        let served = try await GitHubManifestPage.serve(manifest)
        guard scope == version else {
          served.stop()
          return
        }
        page = served
        knownApps = known
        depart(GitHubTrip(step: .create, url: served.url), client: client)
      } catch {
        guard scope == version else { return }
        saveError = friendlyError(error)
      }
      isOpening = false
    }
  }

  public func install(_ app: GitHubApp, client: APIClient) {
    guard canLeave, let url = URL(string: app.installUrl) else { return }
    errors[app.id] = nil
    depart(GitHubTrip(step: .install(appID: app.id), url: url), client: client)
  }

  public func signIn(_ app: GitHubApp, client: APIClient) {
    guard canLeave else { return }
    errors[app.id] = nil
    isOpening = true
    let version = scope
    Task {
      do {
        let url = try await client.signInGitHubApp(appID: app.id)
        guard scope == version else { return }
        depart(GitHubTrip(step: .signIn(appID: app.id), url: url), client: client)
      } catch {
        guard scope == version else { return }
        errors[app.id] = friendlyError(error)
      }
      isOpening = false
    }
  }

  /// The owner gave up, or isn't coming back. The server may still finish, so the list is read again.
  public func stopWaiting(client: APIClient) {
    leave()
    refresh(client: client)
  }

  /// The system browser sheet closed. A step that just finished still counts.
  public func browserClosed(_ trip: GitHubTrip, client: APIClient) {
    guard self.trip?.id == trip.id else { return }
    following?.cancel()
    let version = scope
    Task {
      do {
        let arrived = try await hasArrived(trip, version: version, client: client)
        guard scope == version, self.trip?.id == trip.id else { return }
        finish(trip, failure: arrived ? nil : Self.unfinished(trip))
        if arrived { refresh(client: client) }
      } catch {
        guard scope == version, self.trip?.id == trip.id else { return }
        finish(trip, failure: friendlyError(error))
      }
    }
  }

  private func depart(_ next: GitHubTrip, client: APIClient) {
    trip = next
    let version = scope
    following = Task {
      let deadline = ContinuousClock.now + next.lifetime
      while !Task.isCancelled, ContinuousClock.now < deadline {
        try? await Task.sleep(for: pollInterval)
        guard !Task.isCancelled, scope == version, trip?.id == next.id else { return }
        // Connection errors and "not installed yet" keep waiting.
        let arrived = (try? await hasArrived(next, version: version, client: client)) ?? false
        guard !Task.isCancelled, scope == version, trip?.id == next.id else { return }
        if arrived {
          finish(next, failure: nil)
          refresh(client: client)
          return
        }
      }
      guard !Task.isCancelled, scope == version, trip?.id == next.id else { return }
      finish(next, failure: "GitHub's step expired. Start again.")
    }
  }

  /// A stale answer still says whether the trip arrived, but only a current one touches the board.
  private func hasArrived(_ trip: GitHubTrip, version: Int, client: APIClient) async throws -> Bool {
    reads += 1
    let read = reads
    var isCurrent: Bool { scope == version && read > settledRead }
    func readApps() async throws -> [GitHubApp] {
      let apps = try await client.gitHubApps()
      if isCurrent {
        settledRead = read
        take(apps)
      }
      return apps
    }
    switch trip.step {
    case .create:
      return try await readApps().contains { !knownApps.contains($0.id) }
    case let .signIn(appID):
      return try await readApps().first { $0.id == appID }?.user != nil
    case let .install(appID):
      do {
        let connected = try await client.connectGitHubApp(appID: appID)
        if isCurrent { store(connected) }
        return true
      } catch let error as APIError where error.statusCode == 409 {
        return false
      }
    }
  }

  private func finish(_ trip: GitHubTrip, failure: String?) {
    leave()
    guard let failure else {
      if trip.step == .create { closeNew() }
      return
    }
    if let appID = trip.appID {
      errors[appID] = failure
    } else {
      saveError = failure
    }
  }

  private func leave() {
    following?.cancel()
    following = nil
    page?.stop()
    page = nil
    trip = nil
  }

  private static func unfinished(_ trip: GitHubTrip) -> String {
    switch trip.step {
    case .create:
      "Crumble hasn't seen a new App. The server's web page finishes this step, so sign in there in your "
        + "browser and start again. If GitHub created the App, delete it there first."
    case .install:
      "GitHub hasn't installed the App. Install it there, then choose Check."
    case .signIn:
      "Crumble hasn't seen this sign-in. The server's web page finishes it, so sign in there in your "
        + "browser and try again."
    }
  }
}
