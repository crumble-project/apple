import Foundation

/// Replaces the selection, or appends when there is none, with a line break; returns the text and the caret after it.
public func insertingNewline(into text: String, replacing range: Range<String.Index>?) -> (
  text: String, caret: String.Index
) {
  var range = range ?? text.endIndex..<text.endIndex
  if range.upperBound > text.endIndex { range = text.endIndex..<text.endIndex }
  let offset = text.distance(from: text.startIndex, to: range.lowerBound)
  var edited = text
  edited.replaceSubrange(range, with: "\n")
  return (edited, edited.index(edited.startIndex, offsetBy: offset + 1))
}

public func messageLabel(_ message: Message) -> String {
  if message.role == "assistant" { return "Agent" }
  if message.role != "user" { return "Tool result" }
  if message.origin?.kind == "task" { return "Task · " + (message.origin?.name ?? "") }
  if message.origin?.kind == "bot" { return "From " + (message.origin?.name ?? "") }
  if message.origin?.kind == "coding" { return "Coding job · " + (message.origin?.name ?? "") }
  return "You"
}

public func preview(_ text: String) -> String {
  var plain = text
  for mark in ["**", "__", "`", "# ", "> "] {
    plain = plain.replacingOccurrences(of: mark, with: "")
  }
  plain = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  return plain.count > 120 ? String(plain.prefix(119)) + "…" : plain
}
