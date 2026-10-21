import Foundation
import Synchronization
import Testing
@testable import apfelkern

// Shared by the API tests: a URL protocol that answers each test's own host, and a client on it.

struct StubResponse: Sendable {
  var status = 200
  var contentType = "application/json"
  var body: Data
  var hold = false
  /// Sends the body but keeps the connection open, as a live event stream does.
  var open = false
}

final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> StubResponse
  static let handlers = Mutex<[String: Handler]>([:])

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let url = try #require(request.url)
      let handler = try #require(Self.handlers.withLock { $0[url.host ?? ""] })
      let stub = try handler(request)
      if stub.hold { return }
      let response = try #require(HTTPURLResponse(
        url: url, statusCode: stub.status, httpVersion: nil,
        headerFields: ["Content-Type": stub.contentType]))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: stub.body)
      if stub.open { return }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

func requestJSON(_ request: URLRequest) throws -> JSONValue {
  var streamBody = Data()
  if let stream = request.httpBodyStream {
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      streamBody.append(contentsOf: buffer.prefix(count))
    }
  }
  return try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? streamBody)
}

func withClient(
  token: String = "test-token", handler: @escaping ContractURLProtocol.Handler,
  test: (APIClient) async throws -> Void
) async throws {
  let host = UUID().uuidString.lowercased() + ".invalid"
  ContractURLProtocol.handlers.withLock { $0[host] = handler }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ContractURLProtocol.self]
  let session = URLSession(configuration: configuration)
  defer {
    session.invalidateAndCancel()
    _ = ContractURLProtocol.handlers.withLock { $0.removeValue(forKey: host) }
  }
  try await test(APIClient(baseURL: "https://" + host + "/prefix/", token: token, session: session))
}
