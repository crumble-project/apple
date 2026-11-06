import Foundation

// These endpoints sit outside the `/v1` contract, as sign-in does, and take the bearer session.
extension APIClient {
  func passkeys() async throws -> [Passkey] {
    struct Wire: Decodable {
      var id: String
      var name: String?
      var createdAt: String
      var backedUp: Bool
    }
    let passkeys: [Wire]? = try await call("GET", "/api/auth/passkey/list-user-passkeys")
    return (passkeys ?? []).map { Passkey(id: $0.id, name: $0.name, createdAt: $0.createdAt, backedUp: $0.backedUp) }
  }

  /// Uses an ephemeral session as sign-out does: a stored auth cookie would make the server answer 403.
  func renamePasskey(_ id: String, name: String, session: URLSession) async throws {
    struct Update: Encodable {
      var id: String
      var name: String
    }
    _ = try await APIClient(baseURL: baseURL, token: token, session: session)
      .send("POST", "/api/auth/passkey/update-passkey", body: Update(id: id, name: name))
  }

  func removePasskey(_ id: String, session: URLSession) async throws {
    struct Delete: Encodable { var id: String }
    _ = try await APIClient(baseURL: baseURL, token: token, session: session)
      .send("POST", "/api/auth/passkey/delete-passkey", body: Delete(id: id))
  }
}
