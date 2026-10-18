import SwiftUI

extension View {
  /// The bubble a message sits in: the accent color for the owner, a quiet gray otherwise.
  func bubble(owner: Bool) -> some View {
    padding(.horizontal, 14)
      .padding(.vertical, 8)
      .foregroundStyle(owner ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .background(
        owner ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.07)),
        in: .rect(cornerRadius: 18))
  }
}

/// Replaces the selection, or appends when there is none, with a line break; returns the text and the caret after it.
func insertingNewline(into text: String, replacing range: Range<String.Index>?) -> (
  text: String, caret: String.Index
) {
  var range = range ?? text.endIndex..<text.endIndex
  if range.upperBound > text.endIndex { range = text.endIndex..<text.endIndex }
  let offset = text.distance(from: text.startIndex, to: range.lowerBound)
  var edited = text
  edited.replaceSubrange(range, with: "\n")
  return (edited, edited.index(edited.startIndex, offsetBy: offset + 1))
}

func messageLabel(_ message: Message) -> String {
  if message.role == "assistant" { return "Agent" }
  if message.role != "user" { return "Tool result" }
  if message.origin?.kind == "task" { return "Task · " + (message.origin?.name ?? "") }
  if message.origin?.kind == "bot" { return "From " + (message.origin?.name ?? "") }
  return "You"
}

func preview(_ text: String) -> String {
  var plain = text
  for mark in ["**", "__", "`", "# ", "> "] {
    plain = plain.replacingOccurrences(of: mark, with: "")
  }
  plain = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  return plain.count > 120 ? String(plain.prefix(119)) + "…" : plain
}
