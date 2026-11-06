import Foundation
import SwiftUI
import WebKit

extension EnvironmentValues {
  /// The server whose Pele module draws Mermaid diagrams; without it they stay source code.
  @Entry public var diagramServer: URL?
}

/// A Mermaid diagram drawn by the same Pele module the web loads from the server. SwiftUI can't
/// show the SVG Pele writes, so a web view hosts it. A source Pele refuses shows as code.
struct DiagramView: View {
  let source: String
  @Environment(\.diagramServer) private var server
  @State private var height: CGFloat = 160
  @State private var failed = false

  var body: some View {
    if let server, !failed {
      DiagramWebView(source: source, server: server, height: $height, failed: $failed)
        .frame(minWidth: 220, idealWidth: 480, maxWidth: .infinity)
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 8))
        // The chat keeps scroll gestures that start over a diagram.
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Diagram")
        .accessibilityValue(source)
    } else {
      CodeBlock(code: source)
    }
  }
}

#if os(macOS)
  private typealias WebViewRepresentable = NSViewRepresentable
#else
  private typealias WebViewRepresentable = UIViewRepresentable
#endif

private struct DiagramWebView: WebViewRepresentable {
  private static let messageName = "diagram"

  let source: String
  let server: URL
  @Binding var height: CGFloat
  @Binding var failed: Bool

  func makeCoordinator() -> Coordinator { Coordinator(view: self) }

  #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context) }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
  #else
    func makeUIView(context: Context) -> WKWebView {
      let webView = makeWebView(context)
      webView.isOpaque = false
      webView.backgroundColor = .clear
      webView.scrollView.isScrollEnabled = false
      return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context) }
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView) }
  #endif

  private func makeWebView(_ context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: Self.messageName)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    return webView
  }

  private func update(_ webView: WKWebView, _ context: Context) {
    context.coordinator.view = self
    guard context.coordinator.loaded != source else { return }
    context.coordinator.loaded = source
    context.coordinator.navigated = false
    webView.loadHTMLString(DiagramPage.html(source: source), baseURL: server)
  }

  private static func dismantle(_ webView: WKWebView) {
    webView.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var view: DiagramWebView
    var loaded: String?
    var navigated = false

    init(view: DiagramWebView) {
      self.view = view
    }

    /// The page posts its height, or a negative number when Pele fails.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let height = message.body as? Double else { return }
      if height < 0 {
        view.failed = true
      } else if height > 0 {
        view.height = height
      }
    }

    /// Bot text is untrusted, so the page never goes anywhere after its first load.
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(navigated ? .cancel : .allow)
      navigated = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
      view.failed = true
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error
    ) {
      view.failed = true
    }
  }
}

/// The source travels as Base64 and only reaches Pele, which escapes it, so bot text can't inject markup.
enum DiagramPage {
  static func html(source: String) -> String {
    let encoded = Data(source.utf8).base64EncodedString()
    let nonce = UUID().uuidString
    return """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" \
      content="default-src 'none'; script-src 'self' 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src data:">
      <style>\(style)</style>
      </head>
      <body><div id="diagram" data-source="\(encoded)"></div>
      <script type="module" nonce="\(nonce)">\(script)</script>
      </body>
      </html>
      """
  }

  private static let script = """
    const box = document.getElementById("diagram");
    const post = (value) => webkit.messageHandlers.diagram.postMessage(value);
    const bytes = Uint8Array.from(atob(box.dataset.source), (character) => character.charCodeAt(0));
    try {
      const { mountAsync } = await import("/ui-modules/pele/lazy.js");
      const mounted = await mountAsync(box, new TextDecoder().decode(bytes), {
        links: false, images: false, zoom: false, onError: () => post(-1)
      });
      if (mounted.error) {
        post(-1);
      } else {
        const report = () => post(Math.ceil(box.getBoundingClientRect().height));
        report();
        new ResizeObserver(report).observe(box);
      }
    } catch {
      post(-1);
    }
    """

  private static let style = """
    :root {
      color-scheme: light dark;
      --pele-bg: transparent;
      --pele-fg: #1d1d1f;
      --pele-muted: #6e6e73;
      --pele-line: #6e6e73;
      --pele-surface: #ffffff;
      --pele-surface-alt: #f2f2f7;
      --pele-border: #d1d1d6;
      --pele-accent: #0a84ff;
      --pele-font: -apple-system, sans-serif;
      --pele-radius: 6px;
      background: #ffffff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --pele-fg: #f5f5f7;
        --pele-muted: #a1a1a6;
        --pele-line: #a1a1a6;
        --pele-surface: #1c1c1e;
        --pele-surface-alt: #2c2c2e;
        --pele-border: #3a3a3c;
        background: #1c1c1e;
      }
    }
    html, body { margin: 0; overflow: hidden; }
    #diagram { padding: 8px; }
    """
}
