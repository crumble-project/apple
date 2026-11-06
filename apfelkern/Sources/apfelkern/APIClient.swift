import Foundation

public struct APIError: Error, LocalizedError, Sendable {
  public var method: String
  public var path: String
  public var statusCode: Int
  public var body: String

  public var errorDescription: String? { "api \(method) \(path) (\(statusCode)): \(body)" }

  public init(method: String, path: String, statusCode: Int, body: String) {
    self.method = method
    self.path = path
    self.statusCode = statusCode
    self.body = body
  }
}

public enum AccountSignInError: Error, LocalizedError, Equatable {
  case invalidCredentials
  case noSession
  /// The server's own reason, such as closed sign-up or a password that's too short.
  case rejected(String)

  public var errorDescription: String? {
    switch self {
    case .invalidCredentials: "Invalid email or password."
    case .noSession: "Sign-in returned no session."
    case let .rejected(message): message
    }
  }
}

public struct SSEClosedError: Error, LocalizedError {
  public init() {}
  public var errorDescription: String? { "server-sent event stream closed" }
}

/// App-facing operations backed by the pinned generated client and an injectable URLSession.
public struct APIClient: Sendable {
  public let baseURL: String
  public let token: String
  public let session: URLSession

  public init(baseURL: String, token: String, session: URLSession = .shared) {
    var trimmed = baseURL
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    self.baseURL = trimmed
    self.token = token
    self.session = session
  }

  /// An escape hatch for endpoints outside the pinned contract. Contract operations don't use it.
  public func send(
    _ method: String, _ path: String, body: (any Encodable)? = nil, headers: [String: String] = [:],
    timeout: TimeInterval = 20
  ) async throws -> Data {
    guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw APIError(
        method: method, path: path, statusCode: status,
        body: decodeUTF8(data.prefix(8 << 10)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return data
  }

  /// Signs in to the server's account endpoint, which sits outside the `/v1` contract, and returns the bearer token.
  /// Uses an ephemeral session: a stored auth cookie without an Origin header makes the server answer 403.
  public static func signIn(
    baseURL: String, email: String, password: String,
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> String {
    struct Credentials: Encodable { var email, password: String }
    return try await accountSession(
      "/api/auth/sign-in/email", body: Credentials(email: email, password: password), baseURL: baseURL,
      session: session)
  }

  /// Creates an account and returns its bearer token. An invite link gets past closed sign-up.
  public static func signUp(
    baseURL: String, name: String, email: String, password: String, invite: String?,
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> String {
    struct Account: Encodable { var name, email, password: String }
    return try await accountSession(
      "/api/auth/sign-up/email", body: Account(name: name, email: email, password: password),
      headers: invite.map { [inviteHeader: $0] } ?? [:], baseURL: baseURL, session: session)
  }

  private static let inviteHeader = "x-crumble-invite"

  private static func accountSession(
    _ path: String, body: any Encodable, headers: [String: String] = [:], baseURL: String, session: URLSession
  ) async throws -> String {
    struct Session: Decodable { var token: String? }
    struct Refusal: Decodable { var message: String }
    let client = APIClient(baseURL: baseURL, token: "", session: session)
    do {
      let result: Session = try await client.call("POST", path, body: body, headers: headers)
      guard let token = result.token, !token.isEmpty else { throw AccountSignInError.noSession }
      return token
    } catch let error as APIError where error.statusCode == 401 {
      throw AccountSignInError.invalidCredentials
    } catch let error as APIError {
      guard let refusal = try? JSONDecoder().decode(Refusal.self, from: Data(error.body.utf8)) else { throw error }
      throw AccountSignInError.rejected(refusal.message)
    }
  }

  /// Ends this session on the server. Uses an ephemeral session for the same reason sign-in does: a
  /// stored auth cookie would make the server answer 403.
  public func signOut(session: URLSession = URLSession(configuration: .ephemeral)) async throws {
    _ = try await APIClient(baseURL: baseURL, token: token, session: session).send("POST", "/api/auth/sign-out")
  }

  public func call<T: Decodable>(
    _ method: String, _ path: String, body: (any Encodable)? = nil, headers: [String: String] = [:],
    timeout: TimeInterval = 20
  ) async throws -> T {
    try JSONDecoder().decode(
      T.self, from: try await send(method, path, body: body, headers: headers, timeout: timeout))
  }
}
