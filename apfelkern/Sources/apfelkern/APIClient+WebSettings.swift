import Foundation

/// A page of the web client's Settings, the only client that configures the server.
public enum WebSettingsPage: String, Sendable {
  case overview = ""
  case providers
  case passwordManagers = "password-managers"
  case eventRelay = "event-relay"
}

extension APIClient {
  /// The server's web UI: the contract takes only an http(s) origin.
  var webOrigin: String {
    get throws {
      guard var components = URLComponents(string: baseURL) else { throw URLError(.badURL) }
      components.path = ""
      components.query = nil
      components.fragment = nil
      guard let origin = components.string else { throw URLError(.badURL) }
      return origin
    }
  }

  public func webSettingsURL(_ page: WebSettingsPage = .overview) -> URL? {
    let path = page.rawValue.isEmpty ? "/settings" : "/settings/" + page.rawValue
    return (try? webOrigin).flatMap { URL(string: $0 + path) }
  }
}
