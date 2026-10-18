import Foundation

struct APIError: Error, LocalizedError, Sendable {
  var method: String
  var path: String
  var statusCode: Int
  var body: String

  var errorDescription: String? { "api \(method) \(path) (\(statusCode)): \(body)" }
}

struct SSEClosedError: Error, LocalizedError {
  var errorDescription: String? { "server-sent event stream closed" }
}

/// The Crumble server's HTTP API. Every request carries the bearer token when one is set.
struct APIClient: Sendable {
  let baseURL: String
  let token: String
  let session: URLSession

  init(baseURL: String, token: String, session: URLSession = .shared) {
    var trimmed = baseURL
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    self.baseURL = trimmed
    self.token = token
    self.session = session
  }

  private func makeRequest(
    _ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 20
  ) throws -> URLRequest {
    guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    if !token.isEmpty {
      request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  func send(
    _ method: String, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval = 20
  ) async throws -> Data {
    let payload = try body.map { try JSONEncoder().encode($0) }
    let request = try makeRequest(method, path, body: payload, timeout: timeout)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let text = String(decoding: data.prefix(8 << 10), as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      throw APIError(method: method, path: path, statusCode: status, body: text)
    }
    return data
  }

  func call<T: Decodable>(
    _ method: String, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval = 20
  ) async throws -> T {
    try JSONDecoder().decode(
      T.self, from: try await send(method, path, body: body, timeout: timeout))
  }

  private func perform(
    _ method: String, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval = 20
  ) async throws {
    _ = try await send(method, path, body: body, timeout: timeout)
  }

  private static func escape(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
  }

  func agents() async throws -> [Agent] { try await call("GET", "/v1/agents") }
  func createAgent(_ agent: Agent) async throws -> Agent {
    try await call("POST", "/v1/agents", body: agent)
  }
  func updateAgent(_ id: String, patch: [String: JSONValue]) async throws -> Agent {
    try await call("PATCH", "/v1/agents/\(id)", body: patch)
  }
  func deleteAgent(_ id: String) async throws { try await perform("DELETE", "/v1/agents/\(id)") }
  func duplicateAgent(_ id: String) async throws -> Agent {
    try await call("POST", "/v1/agents/\(id)/duplicate")
  }

  func chat(_ agentID: String) async throws -> ChatSnapshot {
    try await call("GET", "/v1/agents/\(agentID)/chat")
  }
  func chatHistory(_ agentID: String, before: String, limit: Int) async throws
    -> ChatHistoryResponse
  {
    var query: [String] = []
    if !before.isEmpty { query.append("before=" + Self.escape(before)) }
    if limit > 0 { query.append("limit=\(limit)") }
    let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
    return try await call("GET", "/v1/agents/\(agentID)/chat/history" + suffix)
  }
  func sendChatMessage(
    _ agentID: String, content: String, requestID: String, replyTo: String,
    attachments: [OutgoingAttachment] = []
  ) async throws {
    struct Body: Encodable {
      var content: String
      var requestId: String
      var replyTo: String?
      var attachments: [OutgoingAttachment]?
    }
    let body = Body(
      content: content, requestId: requestID, replyTo: replyTo.nilIfEmpty,
      attachments: attachments.isEmpty ? nil : attachments)
    // Images take a while to upload; the default timeout is for small requests.
    try await perform(
      "POST", "/v1/agents/\(agentID)/messages", body: body, timeout: attachments.isEmpty ? 20 : 120)
  }
  /// The bytes of an attached image, by its position in the message's attachments.
  func attachment(_ agentID: String, entryID: String, index: Int) async throws -> Data {
    try await send("GET", "/v1/agents/\(agentID)/attachments/\(Self.escape(entryID))/\(index)")
  }
  func abortChat(_ agentID: String) async throws {
    try await perform("POST", "/v1/agents/\(agentID)/abort")
  }
  func compactChat(_ agentID: String) async throws {
    try await perform("POST", "/v1/agents/\(agentID)/compact")
  }

  /// Follows the bot chat's server-sent events, passing each snapshot payload to onEvent.
  /// It returns only by throwing: SSEClosedError when the server ends the stream.
  func chatEvents(_ agentID: String, onEvent: @Sendable (String) async -> Void) async throws
    -> Never
  {
    try await events("/v1/agents/\(agentID)/events", parser: SSEParser(), onEvent: onEvent)
  }

  /// Follows server-wide activity: finished replies and sidebar previews from every bot.
  func activityEvents(onEvent: @Sendable (String) async -> Void) async throws -> Never {
    try await events("/v1/events", parser: SSEParser(accepting: ["activity"]), onEvent: onEvent)
  }

  private func events(_ path: String, parser: SSEParser, onEvent: @Sendable (String) async -> Void)
    async throws -> Never
  {
    var parser = parser
    // Heartbeats keep the stream busy; a long idle timeout only ends a stream that has gone silent.
    let request = try makeRequest("GET", path, timeout: 24 * 60 * 60)
    let (bytes, response) = try await session.bytes(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 8 << 10 { break }
      }
      throw APIError(
        method: "GET", path: path, statusCode: status,
        body: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // AsyncLineSequence skips empty lines, so read raw lines to keep the blank line that ends an event.
    var line = Data()
    for try await byte in bytes {
      if byte != UInt8(ascii: "\n") {
        line.append(byte)
        continue
      }
      if line.last == UInt8(ascii: "\r") { line.removeLast() }
      if let payload = try parser.feed(String(decoding: line, as: UTF8.self)) {
        await onEvent(payload)
      }
      line.removeAll(keepingCapacity: true)
    }
    try Task.checkCancellation()
    if let payload = try parser.feed(String(decoding: line, as: UTF8.self)) {
      await onEvent(payload)
    }
    if let payload = try parser.feed("") { await onEvent(payload) }
    throw SSEClosedError()
  }

  /// A bot's memories, or the shared ones when `agentID` is nil.
  private func memoryPath(_ agentID: String?) -> String {
    agentID.map { "/v1/agents/\($0)/memories" } ?? "/v1/memories"
  }
  func memories(_ agentID: String?) async throws -> [Memory] {
    try await call("GET", memoryPath(agentID))
  }
  func addMemory(_ agentID: String?, content: String) async throws -> Memory {
    try await call("POST", memoryPath(agentID), body: ["content": content])
  }
  func updateMemory(_ agentID: String?, memoryID: String, content: String) async throws -> Memory {
    try await call("PATCH", memoryPath(agentID) + "/\(memoryID)", body: ["content": content])
  }
  func deleteMemory(_ agentID: String?, memoryID: String) async throws {
    try await perform("DELETE", memoryPath(agentID) + "/\(memoryID)")
  }

  func sharedSkills() async throws -> [SharedSkill] { try await call("GET", "/v1/skills") }
  func createSharedSkill(name: String, instructions: String) async throws -> SharedSkill {
    try await call("POST", "/v1/skills", body: ["name": name, "instructions": instructions])
  }
  func updateSharedSkill(_ id: String, name: String, instructions: String) async throws
    -> SharedSkill
  {
    try await call("PATCH", "/v1/skills/\(id)", body: ["name": name, "instructions": instructions])
  }
  func deleteSharedSkill(_ id: String) async throws {
    try await perform("DELETE", "/v1/skills/\(id)")
  }

  func schedules() async throws -> [Schedule] { try await call("GET", "/v1/schedules") }
  func createSchedule(_ payload: [String: JSONValue]) async throws -> Schedule {
    try await call("POST", "/v1/schedules", body: payload)
  }
  func updateSchedule(_ id: String, patch: [String: JSONValue]) async throws -> Schedule {
    try await call("PATCH", "/v1/schedules/\(id)", body: patch)
  }
  func deleteSchedule(_ id: String) async throws {
    try await perform("DELETE", "/v1/schedules/\(id)")
  }
  func runSchedule(_ id: String) async throws -> Execution {
    struct Envelope: Decodable { var result: Execution }
    let envelope: Envelope = try await call("POST", "/v1/schedules/\(id)/run")
    return envelope.result
  }
  func executions() async throws -> [Execution] { try await call("GET", "/v1/executions") }
  func activityFeed() async throws -> ActivityFeed { try await call("GET", "/v1/activity/feed") }

  func providers() async throws -> [ProviderStatus] { try await call("GET", "/v1/providers") }
  func models(provider: String) async throws -> [ModelSummary] {
    try await call("GET", "/v1/models?provider=" + Self.escape(provider))
  }
  func setProviderKey(_ provider: String, apiKey: String) async throws {
    try await perform("PUT", "/v1/providers/\(provider)", body: ["apiKey": apiKey])
  }
  func deleteProviderKey(_ provider: String) async throws {
    try await perform("DELETE", "/v1/providers/\(provider)")
  }

  func mcpServers() async throws -> [MCPServer] { try await call("GET", "/v1/mcp-servers") }
  func createMCPServer(_ payload: [String: JSONValue]) async throws -> MCPServer {
    try await call("POST", "/v1/mcp-servers", body: payload)
  }
  func updateMCPServer(_ id: String, patch: [String: JSONValue]) async throws -> MCPServer {
    try await call("PATCH", "/v1/mcp-servers/\(id)", body: patch)
  }
  func deleteMCPServer(_ id: String) async throws {
    try await perform("DELETE", "/v1/mcp-servers/\(id)")
  }
  func startMCPSignIn(_ id: String, redirectURI: String) async throws -> OAuthStart {
    try await call(
      "POST", "/v1/mcp-servers/\(id)/oauth", body: ["redirectUri": redirectURI], timeout: 60)
  }
  func finishMCPSignIn(_ id: String, code: String, state: String, iss: String?) async throws
    -> MCPServer
  {
    var body = ["code": code, "state": state]
    body["iss"] = iss
    return try await call("POST", "/v1/mcp-servers/\(id)/oauth/callback", body: body, timeout: 60)
  }
  func signOutOfMCP(_ id: String) async throws -> MCPServer {
    try await call("DELETE", "/v1/mcp-servers/\(id)/oauth")
  }
}

/// Splits a server-sent event stream into snapshot payloads, line by line. Heartbeats and other
/// event types are skipped; a snapshot without an agentId is a protocol error.
struct SSEParser {
  private var data: [String] = []
  private var eventType = "message"
  private let accepting: Set<String>

  /// The event types whose payloads are passed on; the chat stream's are snapshots.
  init(accepting: Set<String> = ["snapshot", "message"]) {
    self.accepting = accepting
  }

  struct InvalidPayload: Error, LocalizedError {
    var reason: String
    var errorDescription: String? { reason }
  }

  mutating func feed(_ line: String) throws -> String? {
    if line.hasPrefix("event:") {
      eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("data:") {
      data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
    } else if line.isEmpty {
      return try dispatch()
    }
    return nil
  }

  private mutating func dispatch() throws -> String? {
    defer { eventType = "message" }
    guard !data.isEmpty else { return nil }
    let payload = data.joined(separator: "\n")
    data = []
    guard accepting.contains(eventType) else { return nil }
    struct Envelope: Decodable { var agentId: String? }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(payload.utf8)) else {
      throw InvalidPayload(reason: "invalid SSE payload")
    }
    guard let agentID = envelope.agentId, !agentID.isEmpty else {
      throw InvalidPayload(reason: "snapshot event missing agentId")
    }
    return payload
  }
}
