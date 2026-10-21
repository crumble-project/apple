import Foundation
import Testing

@testable import Crumble

struct TransportSecurityTests {
  /// Uses the real URL loading system: URLProtocol stubs bypass ATS and cannot catch this regression.
  /// The reserved TEST-NET address need not respond; connection errors are fine, an ATS block isn't.
  @Test func configuredHTTPServersAreNotBlockedByTransportSecurity() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 0.5
    configuration.timeoutIntervalForResource = 1
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await session.data(from: URL(string: "http://192.0.2.1:7337/health")!)
    } catch {
      let failure = error as NSError
      #expect(
        !(failure.domain == NSURLErrorDomain
          && failure.code == URLError.appTransportSecurityRequiresSecureConnection.rawValue),
        "User-configured HTTP servers must reach the network rather than fail ATS validation."
      )
    }
  }
}
