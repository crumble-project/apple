import Foundation

/// A page a bot searched or read in the turn that wrote a group message.
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
      .replacing(#/[ \t]*\x{E000}/#, with: "")
      .replacing(#/(?i)[ \t]*\((?:\s*sources?:?)?\s*\)/#, with: "")
  }
}
