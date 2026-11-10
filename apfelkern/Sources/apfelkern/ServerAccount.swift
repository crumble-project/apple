import Foundation
import Observation

/// The signed-in account. The server names it only outside the `/v1` contract.
public struct ServerAccount: Hashable, Sendable {
  public var id: String
  public var name: String
  public var email: String
}

/// Who is signed in. Results from an older connection are dropped.
@MainActor @Observable
public final class ServerAccountBoard {
  public private(set) var account: ServerAccount?
  public private(set) var isAccountLoaded = false
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    account = nil
    isAccountLoaded = false
  }

  /// The server answered and doesn't know this session, so the owner has to sign in again.
  public var sessionEnded: Bool { isAccountLoaded && account == nil }

  /// A failed read keeps what was known: only the server's answer can end the session.
  public func loadAccount(client: APIClient) {
    let version = scope
    Task {
      do {
        let session = try await client.serverAccount()
        guard scope == version else { return }
        account = session
        isAccountLoaded = true
      } catch {}
    }
  }
}
