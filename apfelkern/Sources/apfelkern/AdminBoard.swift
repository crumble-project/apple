import Foundation
import Observation

/// Server administration: the signed-in account's role, users, invite links, and server settings.
/// Role changes, removals, revokes, and settings apply at once and come back on failure. An invite
/// link depends on the server, so its sheet waits. Results from an older connection are dropped.
@MainActor @Observable
public final class AdminBoard {
  public private(set) var account: ServerAccount?
  public private(set) var isAccountLoaded = false
  public private(set) var accountError: String?

  private var loadedUsers: [AdminUser] = []
  private var loadedInvites: [PendingInvite] = []
  private var loadedSettings: ServerSettings?
  public private(set) var outdatedWorkspaces: [OutdatedWorkspace] = []
  public private(set) var isLoaded = false
  public private(set) var usersError: String?
  public private(set) var settingsError: String?
  /// Why the last sign-up change failed. Reads leave it, so the follow-up read can't hide it.
  public private(set) var signUpError: String?

  private var reads = 0
  /// Reads up to this one are ignored: they may predate a newer read or a write.
  private var settledRead = 0
  /// Hidden from the list until the server answers, so a read can't bring them back.
  private var removing: Set<String> = []
  private var revoking: Set<String> = []
  /// The role to show for a user until the server answers, so a read can't take it away.
  private var changingRole: [String: UserRole] = [:]
  /// Settings the server hasn't confirmed, oldest first.
  private var settingsWrites: [(id: UUID, patch: ServerSettingsPatch)] = []
  /// Why a change to a user or an invite failed, by id.
  public private(set) var errors: [String: String] = [:]

  /// The open settings sheet, and failed saves waiting for it to close.
  public var draft: ServerSettingsDraft?
  private var returned: [(draft: ServerSettingsDraft, error: String)] = []
  public private(set) var saveError = ""
  /// The only home of a new invite link. Closing the sheet drops the link for good.
  public private(set) var inviteSheet: InviteLinkSheet?
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    account = nil
    isAccountLoaded = false
    accountError = nil
    clearAdminData()
    reads = 0
    settledRead = 0
    removing = []
    revoking = []
    changingRole = [:]
    settingsWrites = []
    errors = [:]
    signUpError = nil
    returned = []
    closeDraft()
    inviteSheet = nil
  }

  private func clearAdminData() {
    loadedUsers = []
    loadedInvites = []
    loadedSettings = nil
    outdatedWorkspaces = []
    isLoaded = false
    usersError = nil
    settingsError = nil
  }

  public var isAdmin: Bool { account?.isAdmin == true }

  public var users: [AdminUser] {
    loadedUsers.filter { !removing.contains($0.id) }.map { user in
      var shown = user
      if let role = changingRole[user.id] { shown.role = role }
      return shown
    }
  }

  public var invites: [PendingInvite] { loadedInvites.filter { !revoking.contains($0.id) } }

  public var settings: ServerSettings? {
    guard var shown = loadedSettings else { return nil }
    for write in settingsWrites { write.patch.apply(to: &shown) }
    return shown
  }

  /// An admin never changes or removes their own account, so they can't lock themselves out here.
  public func canManage(_ user: AdminUser) -> Bool {
    guard let account else { return false }
    return account.isAdmin && account.id != user.id
  }

  public func isUnconfirmed(_ user: AdminUser) -> Bool { changingRole[user.id] != nil }

  /// The account a workspace belongs to, by name, when the list has it.
  public func owner(of workspace: OutdatedWorkspace) -> String? {
    loadedUsers.first { $0.id == workspace.userId }?.shown
  }

  public var isSavingSignUp: Bool { settingsWrites.contains { $0.patch.signUpOpen != nil } }

  // MARK: Reading

  /// Reads only who is signed in, so the apps can show or hide admin surfaces.
  public func loadAccount(client: APIClient) {
    let version = scope
    Task {
      // An open page may have read the account before it was known as an admin's.
      if await readAccount(client: client, version: version), !isLoaded { refresh(client: client) }
    }
  }

  /// Re-reads the role first: another admin may have changed it since the last read.
  public func refresh(client: APIClient) {
    let version = scope
    reads += 1
    let read = reads
    Task {
      guard await readAccount(client: client, version: version) else { return }
      async let users = outcome { try await client.adminUsers() }
      async let invites = outcome { try await client.pendingInvites() }
      async let settings = outcome { try await client.serverSettings() }
      async let outdated = outcome { try await client.outdatedWorkspaces() }
      let (people, links, values, stale) = await (users, invites, settings, outdated)
      guard scope == version, read > settledRead else { return }
      settledRead = read
      apply(people, links, values, stale)
    }
  }

  /// Whether to read admin data. A failed read keeps the known role: the admin reads then report the
  /// failure where the pages show it, and the server refuses them if the role is gone.
  private func readAccount(client: APIClient, version: Int) async -> Bool {
    do {
      let session = try await client.serverAccount()
      guard scope == version else { return false }
      account = session
      isAccountLoaded = true
      accountError = nil
      if session?.isAdmin != true { clearAdminData() }
      return session?.isAdmin == true
    } catch {
      guard scope == version else { return false }
      accountError = friendlyError(error)
      return isAdmin
    }
  }

  private func apply(
    _ people: Result<[AdminUser], Error>, _ links: Result<[PendingInvite], Error>,
    _ values: Result<ServerSettings, Error>, _ stale: Result<[OutdatedWorkspace], Error>
  ) {
    usersError = nil
    settingsError = nil
    do { loadedUsers = try people.get() } catch { usersError = friendlyError(error) }
    do { loadedInvites = try links.get() } catch { usersError = usersError ?? friendlyError(error) }
    do { loadedSettings = try values.get() } catch { settingsError = friendlyError(error) }
    do { outdatedWorkspaces = try stale.get() } catch { settingsError = settingsError ?? friendlyError(error) }
    isLoaded = true
  }

  // MARK: Users

  public func setRole(_ role: UserRole, for user: AdminUser, client: APIClient) {
    guard canManage(user), changingRole[user.id] == nil, !removing.contains(user.id) else { return }
    changingRole[user.id] = role
    errors[user.id] = nil
    let version = scope
    Task {
      do {
        let changed = try await client.setUserRole(userID: user.id, role: role)
        guard scope == version else { return }
        if let index = loadedUsers.firstIndex(where: { $0.id == changed.id }) { loadedUsers[index] = changed }
      } catch {
        guard scope == version else { return }
        errors[user.id] = friendlyError(error)
      }
      settledRead = reads
      changingRole[user.id] = nil
      refresh(client: client)
    }
  }

  public func remove(_ user: AdminUser, client: APIClient) {
    guard canManage(user), !isUnconfirmed(user), removing.insert(user.id).inserted else { return }
    errors[user.id] = nil
    let version = scope
    Task {
      do {
        try await client.removeUser(userID: user.id)
        guard scope == version else { return }
        loadedUsers.removeAll { $0.id == user.id }
      } catch {
        guard scope == version else { return }
        errors[user.id] = friendlyError(error)
      }
      settledRead = reads
      removing.remove(user.id)
      refresh(client: client)
    }
  }

  // MARK: Invite links

  /// Mints one link per sheet: it opens here, from the owner's tap, and never from a read.
  public func createInvite(client: APIClient) {
    guard inviteSheet == nil else { return }
    let sheet = InviteLinkSheet()
    inviteSheet = sheet
    let version = scope
    Task {
      do {
        let link = try await client.createInvite()
        guard scope == version else { return }
        if inviteSheet?.id == sheet.id { inviteSheet?.link = link }
      } catch {
        guard scope == version else { return }
        if inviteSheet?.id == sheet.id { inviteSheet?.error = friendlyError(error) }
      }
      settledRead = reads
      refresh(client: client)
    }
  }

  public func closeInviteSheet() {
    inviteSheet = nil
  }

  public func revoke(_ invite: PendingInvite, client: APIClient) {
    guard revoking.insert(invite.id).inserted else { return }
    errors[invite.id] = nil
    let version = scope
    Task {
      do {
        try await client.revokeInvite(inviteID: invite.id)
        guard scope == version else { return }
        loadedInvites.removeAll { $0.id == invite.id }
      } catch {
        guard scope == version else { return }
        errors[invite.id] = friendlyError(error)
      }
      settledRead = reads
      revoking.remove(invite.id)
      refresh(client: client)
    }
  }

  // MARK: Settings

  public func setSignUpOpen(_ open: Bool, client: APIClient) {
    guard !isSavingSignUp else { return }
    signUpError = nil
    write(ServerSettingsPatch(signUpOpen: open), client: client) { [self] error in
      signUpError = error
    }
  }

  /// Never replaces an open sheet: it may hold typed values, or a save that came back.
  public func edit(_ field: ServerSettingsDraft.Field) {
    guard draft == nil, let settings else { return }
    draft = ServerSettingsDraft(field: field, settings: settings)
  }

  public func closeDraft() {
    draft = nil
    saveError = ""
    if !returned.isEmpty {
      let next = returned.removeFirst()
      draft = next.draft
      saveError = next.error
    }
  }

  public func saveDraft(client: APIClient) {
    guard let draft, let patch = draft.patch else { return }
    closeDraft()
    write(patch, client: client) { [self] error in giveBack(draft, error: error) }
  }

  private func giveBack(_ failed: ServerSettingsDraft, error: String) {
    guard draft == nil else {
      returned.append((failed, error))
      return
    }
    draft = failed
    saveError = error
  }

  private func write(
    _ patch: ServerSettingsPatch, client: APIClient, failed: @escaping @MainActor (String) -> Void
  ) {
    let id = UUID()
    settingsWrites.append((id, patch))
    let version = scope
    Task {
      do {
        let saved = try await client.updateServerSettings(patch)
        guard scope == version else { return }
        loadedSettings = saved
      } catch {
        guard scope == version else { return }
        failed(friendlyError(error))
      }
      settledRead = reads
      settingsWrites.removeAll { $0.id == id }
      refresh(client: client)
    }
  }
}

private func outcome<Value: Sendable>(_ work: @Sendable () async throws -> Value) async -> Result<Value, Error> {
  do { return .success(try await work()) } catch { return .failure(error) }
}
