import Foundation
import HTTPTypes
import OpenAPIRuntime

struct ContractTransport: ClientTransport {
  let session: URLSession
  let token: String
  let timeout: TimeInterval
  let nullFields: Set<String>

  /// Server-sent event operations, whose responses never finish; every other response is read whole.
  static let streamingOperations: Set<String> = [
    Operations.StreamChatEvents.id, Operations.StreamGroupChatEvents.id, Operations.StreamActivityEvents.id
  ]

  func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
    async throws -> (HTTPResponse, HTTPBody?) {
    let urlRequest = try await urlRequest(request, body: body, baseURL: baseURL, operationID: operationID)
    if Self.streamingOperations.contains(operationID) {
      let (bytes, response) = try await session.bytes(for: urlRequest)
      let httpResponse = try responseModel(response)
      guard (200..<300).contains(httpResponse.status.code) else {
        var data = Data()
        for try await byte in bytes {
          data.append(byte)
          if data.count >= 8 << 10 { break }
        }
        throw apiError(request, status: httpResponse.status.code, data: data)
      }
      return (httpResponse, HTTPBody(
        bytes.map { CollectionOfOne($0) }, length: .unknown, iterationBehavior: .single))
    }
    let (data, response) = try await session.data(for: urlRequest)
    let httpResponse = try responseModel(response)
    guard (200..<300).contains(httpResponse.status.code) else {
      throw apiError(request, status: httpResponse.status.code, data: data.prefix(8 << 10))
    }
    return (httpResponse, HTTPBody(data))
  }

  private func urlRequest(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
    async throws -> URLRequest {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
          let path = URLComponents(string: request.path ?? "") else { throw URLError(.badURL) }
    components.percentEncodedPath += path.percentEncodedPath
    components.percentEncodedQuery = path.percentEncodedQuery
    guard let url = components.url else { throw URLError(.badURL) }
    var result = URLRequest(url: url, timeoutInterval: timeout)
    result.httpMethod = request.method.rawValue
    for field in request.headerFields { result.addValue(field.value, forHTTPHeaderField: field.name.rawName) }
    if !token.isEmpty { result.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    if let body { result.httpBody = try await Data(collecting: body, upTo: .max) }
    try restoreNullFields(in: &result, operationID: operationID)
    try Task.checkCancellation()
    return result
  }

  private func restoreNullFields(in request: inout URLRequest, operationID: String) throws {
    guard !nullFields.isEmpty else { return }
    let allowed: Set<String>
    switch operationID {
    case Operations.UpdateSchedule.id, Operations.CreateSchedule.id: allowed = ["cron", "runAt"]
    case Operations.PutPushPresence.id: allowed = ["agentId"]
    case Operations.CreateMcpServer.id: allowed = ["agentId"]
    default: allowed = []
    }
    guard nullFields.isSubset(of: allowed), let body = request.httpBody,
          case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: body) else {
      throw EncodingError.invalidValue(nullFields, .init(
        codingPath: [], debugDescription: "Invalid nullable request fields"))
    }
    for field in nullFields { object[field] = .null }
    request.httpBody = try JSONEncoder().encode(JSONValue.object(object))
  }

  private func responseModel(_ response: URLResponse) throws -> HTTPResponse {
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var result = HTTPResponse(status: .init(code: response.statusCode))
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, let name = HTTPField.Name(key), let value = value as? String {
        result.headerFields.append(HTTPField(name: name, value: value))
      }
    }
    return result
  }

  private func apiError(_ request: HTTPRequest, status: Int, data: Data) -> APIError {
    APIError(method: request.method.rawValue, path: request.path ?? "", statusCode: status,
             body: decodeUTF8(data).trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

func decodeUTF8(_ data: Data) -> String {
  #if os(iOS)
  String(bytes: data, encoding: .utf8) ?? String(unsafeUninitializedCapacity: data.count) { buffer in
    data.copyBytes(to: buffer)
  }
  #else
  String(data: data, encoding: .utf8) ?? ""
  #endif
}

extension APIClient {
  func invoke<T: Sendable>(
    timeout: TimeInterval = 20, nullFields: Set<String> = [], _ operation: @Sendable (Client) async throws -> T
  ) async throws -> T {
    guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
    let client = Client(serverURL: url, configuration: .init(dateTranscoder: .iso8601WithFractionalSeconds),
      transport: ContractTransport(session: session, token: token, timeout: timeout, nullFields: nullFields))
    do {
      return try await operation(client)
    } catch let error as ClientError {
      if Task.isCancelled { throw CancellationError() }
      throw error.underlyingError
    }
  }

  func requestModel<T: Decodable>(_ model: some Encodable) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      do { return try ISO8601DateTranscoder.iso8601WithFractionalSeconds.decode(text) } catch {
        return try ISO8601DateTranscoder.iso8601.decode(text)
      }
    }
    return try decoder.decode(T.self, from: JSONEncoder().encode(model))
  }

  func required<T>(_ value: T?) throws -> T {
    guard let value else {
      throw DecodingError.valueNotFound(
        T.self, .init(codingPath: [], debugDescription: "Expected a non-null API resource"))
    }
    return value
  }
}
