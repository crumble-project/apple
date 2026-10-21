import apfelkern
import Foundation

@testable import Crumble

struct ControlledHTTPResponse: Sendable {
  var status: Int
  var body: Data
}

actor ControlledDeliveryController {
  private var postCount = 0
  private var pendingResponses: [Int: CheckedContinuation<ControlledHTTPResponse, Never>] = [:]

  func response(for request: URLRequest) async -> ControlledHTTPResponse {
    guard request.httpMethod == "POST", request.url?.path.hasSuffix("/messages") == true else {
      if request.url?.path == "/v1/agents" {
        return ControlledHTTPResponse(status: 200, body: Data("[]".utf8))
      }
      if let path = request.url?.path, path.hasSuffix("/chat"),
        let agentID = path.split(separator: "/").dropLast().last {
        return ControlledHTTPResponse(
          status: 200,
          body: Data(ContractFixtures.snapshot(String(agentID)).utf8))
      }
      return ControlledHTTPResponse(status: 200, body: Data())
    }

    postCount += 1
    let sequence = postCount
    return await withCheckedContinuation { continuation in
      pendingResponses[sequence] = continuation
    }
  }

  func observedPostCount() -> Int { postCount }

  func completePost(_ sequence: Int, status: Int, body: String? = nil) {
    let responseBody = body ?? (status == 202 ? ContractFixtures.execution() : "")
    pendingResponses.removeValue(forKey: sequence)?.resume(
      returning: ControlledHTTPResponse(status: status, body: Data(responseBody.utf8)))
  }
}

/// A URLProtocol adapter with per-host controls so each test session owns its held POSTs.
final class ControlledDeliveryProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) private static var controllers: [String: ControlledDeliveryController] = [:]
  private static let controllersLock = NSLock()

  static func register(_ controller: ControlledDeliveryController, for host: String) {
    controllersLock.lock()
    controllers[host] = controller
    controllersLock.unlock()
  }

  override static func canInit(with request: URLRequest) -> Bool { request.url?.host != nil }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let host = request.url?.host else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    Self.controllersLock.lock()
    let controller = Self.controllers[host]
    Self.controllersLock.unlock()
    guard let controller else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }

    Task {
      let result = await controller.response(for: request)
      guard let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: nil)
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !result.body.isEmpty { client?.urlProtocol(self, didLoad: result.body) }
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

extension ControlledDeliveryController {
  func waitForPosts(_ count: Int) async -> Bool {
    for _ in 0..<500 {
      if observedPostCount() >= count { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

extension ControlledDeliveryProtocol {
  static func client() -> (APIClient, ControlledDeliveryController) {
    let host = "delivery-\(UUID().uuidString.lowercased()).test"
    let controller = ControlledDeliveryController()
    register(controller, for: host)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledDeliveryProtocol.self]
    let client = APIClient(
      baseURL: "http://\(host)/", token: "", session: URLSession(configuration: configuration))
    return (client, controller)
  }
}
