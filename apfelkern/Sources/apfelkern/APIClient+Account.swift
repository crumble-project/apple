import Foundation

extension APIClient {
  /// The signed-in account, or nil when the server doesn't know this session. This endpoint sits
  /// outside the `/v1` contract, as sign-in does.
  public func serverAccount() async throws -> ServerAccount? {
    struct User: Decodable {
      var id: String
      var name: String
      var email: String
    }
    struct Session: Decodable { var user: User }
    let session: Session? = try await call("GET", "/api/auth/get-session")
    return session.map {
      ServerAccount(id: $0.user.id, name: $0.user.name, email: $0.user.email)
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
}
