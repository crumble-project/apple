import Foundation

/// A page a bot searched or read in the turn that wrote a message.
public struct MessageSource: Codable, Hashable, Sendable {
  public var url: String
  public var title: String

  public init(url: String, title: String) {
    self.url = url
    self.title = title
  }
}

/// A cited page, shown once after the reply instead of as a link inside it.
public struct SourceChip: Hashable, Sendable {
  public var href: String
  public var title: String

  public init(href: String, title: String) {
    self.href = href
    self.title = title
  }
}

/// Takes a reply's citations of pages its turn read out of its text, as the web transcript does.
public enum SourceCitations {
  // A private-use character marks where a chip was; bot text never contains it.
  private static let slot = "\u{E000}"
  private static let pageTools: Set<String> = ["web_search", "web_extract"]

  /// Removes `[source](url)` links to known pages, outside code, and returns those pages once each.
  public static func split(_ markdown: String, sources: [MessageSource]) -> (text: String, chips: [SourceChip]) {
    let known = Dictionary(
      sources.compactMap { source in key(source.url).map { ($0, source.title) } },
      uniquingKeysWith: { first, _ in first })
    guard !known.isEmpty else { return (markdown, []) }
    var chips: [(key: String, chip: SourceChip)] = []
    var fenced = false
    let lines = markdown.components(separatedBy: "\n").map { line -> String in
      let fence = line.drop { $0 == " " || $0 == "\t" }
      if fence.hasPrefix("```") || fence.hasPrefix("~~~") {
        fenced.toggle()
        return line
      }
      return fenced ? line : take(from: line, known: known, chips: &chips)
    }
    return (lines.joined(separator: "\n"), chips.map(\.chip))
  }

  /// For each bot reply, the pages its turn searched or read; a turn starts at each message to the bot. A bot chat has
  /// no `sources` on the wire, so they come from its tool results; a group chat's server stores them on the message.
  public static func byReply(_ messages: [Message]) -> [String: [MessageSource]] {
    var replies: [String: [MessageSource]] = [:]
    var turn: [MessageSource] = []
    for message in messages {
      if message.role == "user" { turn = [] }
      turn += pages(of: message)
      if message.role == "assistant", !turn.isEmpty { replies[message.id] = turn }
    }
    return replies
  }

  /// A page that could not be read carries an error instead of a title.
  private static func pages(of message: Message) -> [MessageSource] {
    guard message.role == "toolResult", message.isError != true, pageTools.contains(message.toolName ?? ""),
      case .array(let pages)? = message.toolDetails
    else { return [] }
    return pages.compactMap { page in
      guard let url = page["url"]?.stringValue, let title = page["title"]?.stringValue else { return nil }
      return MessageSource(url: url, title: title)
    }
  }

  /// Ignores the fragment, a trailing slash, and the host's case, so a cited link matches the page that was read.
  static func key(_ href: String) -> String? {
    guard let url = URLComponents(string: href), ["http", "https"].contains(url.scheme?.lowercased()),
      let host = url.host?.lowercased().nilIfEmpty
    else { return nil }
    var path = url.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    return host + (url.port.map { ":\($0)" } ?? "") + path + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
  }

  private static func take(
    from line: String, known: [String: String], chips: inout [(key: String, chip: SourceChip)]
  ) -> String {
    var result = ""
    var rest = line[...]
    for code in line.ranges(of: #/`[^`]*`/#) {
      result += clean(rest[rest.startIndex..<code.lowerBound], known: known, chips: &chips)
      result += line[code]
      rest = line[code.upperBound...]
    }
    return result + clean(rest, known: known, chips: &chips)
  }

  private static func clean(
    _ prose: Substring, known: [String: String], chips: inout [(key: String, chip: SourceChip)]
  ) -> String {
    var found = chips
    let marked = prose.replacing(#/(?i)\[sources?\]\((https?:\/\/[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)\)/#) { match in
      let href = String(match.output.1)
      guard let key = key(href), let title = known[key] else { return String(match.output.0) }
      if !found.contains(where: { $0.key == key }) { found.append((key, SourceChip(href: href, title: title))) }
      return slot
    }
    chips = found
    return String(marked)
      .replacing(#/\x{E000}[ \t]*(?:,|;|&|and)[ \t]*(?=\x{E000})/#, with: slot)
      // Only parentheses that held a citation go: a literal `()` in the prose is the bot's own text.
      .replacing(#/(?i)[ \t]*\((?:\s*sources?:?)?[\s\x{E000}]*\x{E000}\s*\)/#, with: "")
      .replacing(#/[ \t]*\x{E000}/#, with: "")
  }
}
