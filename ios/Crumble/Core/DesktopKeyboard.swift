import Foundation
import Observation
import WebKit

/// Sends on-screen keyboard input to the viewer page. noVNC only reads key events on its canvas, which can't summon
/// the iOS keyboard, so the app has its own text field and hands each key to the canvas.
@MainActor @Observable
final class DesktopKeyboard {
  enum Key: String, CaseIterable, Identifiable {
    case escape = "Escape"
    case tab = "Tab"
    case arrowLeft = "ArrowLeft"
    case arrowUp = "ArrowUp"
    case arrowDown = "ArrowDown"
    case arrowRight = "ArrowRight"
    case enter = "Enter"
    case backspace = "Backspace"

    var id: String { rawValue }
  }

  /// A key per Unicode scalar; noVNC maps one UTF-16 unit to a keysym, so it can't send what doesn't fit one.
  nonisolated static func keys(for text: String) -> [String] {
    text.unicodeScalars.compactMap { scalar in
      switch scalar {
      case "\n", "\r": Key.enter.rawValue
      case "\t": Key.tab.rawValue
      default: scalar.value <= 0xFFFF ? String(scalar) : nil
      }
    }
  }

  private static let dispatch = """
    const canvas = document.querySelector("#screen canvas");
    for (const key of keys) {
      for (const type of ["keydown", "keyup"]) {
        canvas.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true, cancelable: true }));
      }
    }
    """

  @ObservationIgnored weak var webView: WKWebView?

  func type(_ text: String) { send(Self.keys(for: text)) }

  func press(_ key: Key) { send([key.rawValue]) }

  private func send(_ keys: [String]) {
    webView?.callAsyncJavaScript(
      Self.dispatch, arguments: ["keys": keys], in: nil, in: .page, completionHandler: nil)
  }
}
