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

  public var errorDescription: String? {
    switch self {
    case .invalidCredentials: "Invalid email or password."
    case .noSession: "Sign-in returned no session."
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
    _ method: String, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval = 20
  ) async throws -> Data {
    guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
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
    struct Session: Decodable { var token: String? }
    let client = APIClient(baseURL: baseURL, token: "", session: session)
    do {
      let result: Session = try await client.call(
        "POST", "/api/auth/sign-in/email", body: Credentials(email: email, password: password))
      guard let token = result.token, !token.isEmpty else { throw AccountSignInError.noSession }
      return token
    } catch let error as APIError where error.statusCode == 401 {
      throw AccountSignInError.invalidCredentials
    }
  }

  public func call<T: Decodable>(
    _ method: String, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval = 20
  ) async throws -> T {
    try JSONDecoder().decode(
      T.self, from: try await send(method, path, body: body, timeout: timeout))
  }
}
