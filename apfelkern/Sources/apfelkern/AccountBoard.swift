import Foundation
import Observation

/// An invite link the server made, `<server>/connect?invite=<token>`. Anyone holding it can make an
/// account, so the token stays out of `description` and `dump`.
public struct InviteLink: Hashable, Sendable {
  public let serverURL: String
  public let token: String

  public init?(_ text: String) {
    guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["http", "https"].contains(parts.scheme ?? ""), parts.host?.isEmpty == false,
      parts.path.hasSuffix("/connect"),
      let token = parts.queryItems?.first(where: { $0.name == "invite" })?.value, !token.isEmpty
    else { return nil }
    parts.path = String(parts.path.dropLast("/connect".count))
    parts.query = nil
    parts.fragment = nil
    guard let serverURL = parts.string else { return nil }
    self.serverURL = serverURL
    self.token = token
  }
}

extension InviteLink: CustomStringConvertible, CustomReflectable {
  public var description: String { "InviteLink(\(serverURL))" }
  public var customMirror: Mirror { Mirror(self, children: ["serverURL": serverURL]) }
}

public enum SignOutOutcome: Hashable, Sendable {
  case confirmed
  /// The server didn't confirm it, so its session may still work until it expires.
  case thisDeviceOnly

  public var notice: String {
    switch self {
    case .confirmed: "Signed out"
    case .thisDeviceOnly:
      "Signed out on this device. The server couldn't confirm it, so the session may stay active until it expires."
    }
  }
}

/// The sign-in and sign-up form, and sign-out. The password lives here only until the session is
/// saved. Both depend on the server, so they show as pending and never apply early.
@MainActor @Observable
public final class AccountBoard {
  public enum Mode: Sendable { case signIn, signUp }

  public var mode = Mode.signIn
  public var name = ""
  public var email = ""
  public var password = ""
  public private(set) var invite: InviteLink?
  public private(set) var isSigningOut = false

  public init() {}

  public var isComplete: Bool {
    !email.trimmed.isEmpty && !password.isEmpty && (mode == .signIn || !name.trimmed.isEmpty)
  }

  public var incompleteMessage: String {
    mode == .signIn ? "Enter your email and password." : "Enter your name, email, and password."
  }

  /// Moves a pasted invite link out of the server URL field, which is saved, and leaves its server.
  public func takeInvite(from serverURL: inout String) {
    guard let link = InviteLink(serverURL) else { return }
    invite = link
    mode = .signUp
    serverURL = link.serverURL
  }

  public func removeInvite() { invite = nil }

  public func switchMode() { mode = mode == .signIn ? .signUp : .signIn }

  /// Signs in or creates the account and returns its session token.
  public func createSession(
    baseURL: String, session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> String {
    switch mode {
    case .signIn:
      return try await APIClient.signIn(baseURL: baseURL, email: email.trimmed, password: password, session: session)
    case .signUp:
      let token = try await APIClient.signUp(
        baseURL: baseURL, name: name.trimmed, email: email.trimmed, password: password, invite: invite?.token,
        session: session)
      // The account exists and the invite is spent, so a retry after a later failure has to sign in.
      mode = .signIn
      invite = nil
      return token
    }
  }

  /// The session is saved, so the form can drop what it held.
  public func finish() {
    mode = .signIn
    name = ""
    password = ""
    invite = nil
  }

  /// Ends the session on the server. `release` runs first, for anything that needs the session to
  /// clean up. Signing out never fails: a server that can't confirm it must not keep the owner in.
  public func signOut(
    client: APIClient, release: () async -> Void = {},
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async -> SignOutOutcome {
    isSigningOut = true
    defer {
      isSigningOut = false
      finish()
      email = ""
    }
    await release()
    do {
      try await client.signOut(session: session)
      return .confirmed
    } catch let error as APIError where error.statusCode == 401 {
      return .confirmed
    } catch {
      return .thisDeviceOnly
    }
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
