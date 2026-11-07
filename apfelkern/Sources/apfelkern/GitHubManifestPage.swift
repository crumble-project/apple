import Foundation
import Network

/// GitHub creates an App only from a form post, and the system browser can only be sent to an address.
/// So this serves that form on loopback, at an unguessable path, until the trip ends.
struct GitHubManifestPage: Sendable {
  let url: URL
  private let listener: NWListener

  private static let maxRequestBytes = 8192

  static func serve(_ manifest: GitHubAppManifest) async throws -> GitHubManifestPage {
    let path = "/" + UUID().uuidString
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let response = Data(Self.response(html(manifest)).utf8)
    let queue = DispatchQueue(label: "dev.crumble.github-manifest-page")
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      read(connection, path: path, response: response, received: Data())
    }
    let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          listener.stateUpdateHandler = nil
          guard let port = listener.port else {
            continuation.resume(throwing: URLError(.cannotConnectToHost))
            return
          }
          continuation.resume(returning: port)
        case let .failed(error), let .waiting(error):
          listener.stateUpdateHandler = nil
          listener.cancel()
          continuation.resume(throwing: error)
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
    guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)") else {
      listener.cancel()
      throw URLError(.badURL)
    }
    return GitHubManifestPage(url: url, listener: listener)
  }

  func stop() {
    listener.cancel()
  }

  private static func read(_ connection: NWConnection, path: String, response: Data, received: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequestBytes) { data, _, isComplete, error in
      let request = received + (data ?? Data())
      if request.range(of: Data("\r\n\r\n".utf8)) != nil {
        let wanted = request.starts(with: Data("GET \(path) ".utf8))
        let answer = wanted ? response : Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)
        connection.send(content: answer, completion: .contentProcessed { _ in connection.cancel() })
      } else if isComplete || error != nil || request.count >= maxRequestBytes {
        connection.cancel()
      } else {
        read(connection, path: path, response: response, received: request)
      }
    }
  }

  private static func response(_ html: String) -> String {
    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n"
      + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + html
  }

  /// Submits itself. The button is there if the browser stops the script.
  static func html(_ manifest: GitHubAppManifest) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><title>Opening GitHub…</title></head><body>
    <form method="post" action="\(escaped(manifest.url))">
    <input type="hidden" name="manifest" value="\(escaped(manifest.manifest))">
    <button type="submit">Continue to GitHub</button>
    </form><script>document.forms[0].submit()</script></body></html>
    """
  }

  private static func escaped(_ text: String) -> String {
    text.replacing("&", with: "&amp;").replacing("\"", with: "&quot;")
      .replacing("<", with: "&lt;").replacing(">", with: "&gt;")
  }
}
