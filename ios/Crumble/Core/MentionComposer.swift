import Foundation

/// Find an unfinished @name at the caret, including names containing spaces, but never emails.
func mentionQuery(in text: String, selection: NSRange) -> (range: NSRange, query: String)? {
  let source = text as NSString
  guard selection.length == 0, selection.location <= source.length else { return nil }
  let prefix = source.substring(to: selection.location) as NSString
  let at = prefix.range(of: "@", options: .backwards)
  guard at.location != NSNotFound else { return nil }
  if at.location > 0 {
    let previous = prefix.substring(with: NSRange(location: at.location - 1, length: 1))
    guard
      previous.rangeOfCharacter(from: .whitespacesAndNewlines.union(.punctuationCharacters)) != nil
    else { return nil }
  }
  let query = prefix.substring(from: at.location + 1)
  guard !query.contains("\n"), !query.contains("\u{fffc}") else { return nil }
  return (NSRange(location: at.location, length: selection.location - at.location), query)
}

/// Inline completion stays separate from the editable draft.
struct MentionCompletion {
  let range: NSRange
  let query: String
  let bots: [Agent]

  static func find(in text: String, selection: NSRange, bots: [Agent]) -> MentionCompletion? {
    guard selection.location == (text as NSString).length,
      let match = mentionQuery(in: text, selection: selection),
      match.query.last?.isWhitespace != true
    else { return nil }
    let matches = bots.filter { $0.name.lowercased().hasPrefix(match.query.lowercased()) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    guard !matches.isEmpty else { return nil }
    return MentionCompletion(range: match.range, query: match.query, bots: matches)
  }
}
