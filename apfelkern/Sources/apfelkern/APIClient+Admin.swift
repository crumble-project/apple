import Foundation

extension APIClient {
  /// The signed-in account, or nil when the server doesn't know this session. This endpoint sits
  /// outside the `/v1` contract, as sign-in does.
  public func serverAccount() async throws -> ServerAccount? {
    struct User: Decodable {
      var id: String
      var name: String
      var email: String
      var role: String?
    }
    struct Session: Decodable { var user: User }
    let session: Session? = try await call("GET", "/api/auth/get-session")
    return session.map {
      ServerAccount(id: $0.user.id, name: $0.user.name, email: $0.user.email, isAdmin: $0.user.role == "admin")
    }
  }

  /// The theme saved on the account, or nil when the server has none for this session.
  func accountTheme() async throws -> AppTheme? {
    struct User: Decodable { var theme: AppTheme? }
    struct Session: Decodable { var user: User }
    let session: Session? = try await call("GET", "/api/auth/get-session")
    return session?.user.theme
  }

  /// Uses an ephemeral session as sign-out does: a stored auth cookie would make the server answer 403.
  func setAccountTheme(_ theme: AppTheme, session: URLSession) async throws {
    struct Update: Encodable { var theme: AppTheme }
    _ = try await APIClient(baseURL: baseURL, token: token, session: session)
      .send("POST", "/api/auth/update-user", body: Update(theme: theme))
  }

  public func adminUsers() async throws -> [AdminUser] {
    try await invoke {
      try await $0.listUsers(.init()).ok.body.json.users.map(AdminUser.init(wire:))
    }
  }

  public func setUserRole(userID: String, role: UserRole) async throws -> AdminUser {
    try await invoke {
      AdminUser(wire: try await $0.setUserRole(.init(
        path: .init(id: userID), body: .json(.init(role: role == .admin ? .admin : .user)))).ok.body.json)
    }
  }

  /// The server deletes the account's bots and data before it answers.
  public func removeUser(userID: String) async throws {
    try await invoke(timeout: 60) {
      _ = try await $0.removeUser(.init(path: .init(id: userID))).noContent
    }
  }

  public func pendingInvites() async throws -> [PendingInvite] {
    try await invoke {
      try await $0.listInvites(.init()).ok.body.json.invites.map(PendingInvite.init(wire:))
    }
  }

  /// Mints a one-time invite link and returns it. The server can't show it again.
  func createInvite() async throws -> String {
    try await invoke { try await $0.createInvite(.init()).ok.body.json.value2.url }
  }

  public func revokeInvite(inviteID: String) async throws {
    try await invoke {
      _ = try await $0.revokeInvite(.init(path: .init(id: inviteID))).noContent
    }
  }

  public func outdatedWorkspaces() async throws -> [OutdatedWorkspace] {
    try await invoke {
      try await $0.listOutdatedWorkspaces(.init()).ok.body.json.workspaces.map {
        OutdatedWorkspace(userId: $0.userId, agentId: $0.agentId)
      }
    }
  }

  public func serverSettings() async throws -> ServerSettings {
    try await invoke { ServerSettings(wire: try await $0.getServerSettings(.init()).ok.body.json) }
  }

  public func updateServerSettings(_ patch: ServerSettingsPatch) async throws -> ServerSettings {
    let clearsImage = patch.codingImage == .some(nil)
    return try await invoke(nullFields: clearsImage ? ["codingImage"] : []) {
      ServerSettings(wire: try await $0.updateServerSettings(.init(body: .json(.init(
        codingImage: patch.codingImage.flatMap { $0 }, questionGraceMinutes: patch.questionGraceMinutes,
        signUpOpen: patch.signUpOpen, workspaceCpus: patch.workspaceCpus,
        workspaceMemoryMib: patch.workspaceMemoryMib)))).ok.body.json)
    }
  }
}
