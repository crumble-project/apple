import Foundation

/// A reply split into the blocks both apps render.
public enum MarkdownBlock: Equatable, Sendable {
  public struct Item: Equatable, Sendable {
    public var marker: String
    public var text: String
    public var indent: Int

    public init(marker: String, text: String, indent: Int) {
      self.marker = marker
      self.text = text
      self.indent = indent
    }
  }

  case paragraph(String)
  case heading(Int, String)
  case list([Item])
  case quote(String)
  case code(String)
  /// A fenced Mermaid block.
  case diagram(String)
  /// Trailing holds the columns the delimiter row aligns right.
  case table(columns: [String], rows: [[String]], trailing: Set<Int>)

  public static func parse(_ text: String) -> [MarkdownBlock] {
    var parser = Parser()
    return parser.parse(text)
  }

  private struct Parser {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var items: [Item] = []
    var quote: [String] = []
    var table: [String] = []
    var code: [String]?
    var language = ""

    mutating func flush() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
      if !items.isEmpty { blocks.append(.list(items)) }
      if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
      if !table.isEmpty { blocks.append(MarkdownBlock.table(table)) }
      paragraph = []
      items = []
      quote = []
      table = []
    }

    mutating func parse(_ text: String) -> [MarkdownBlock] {
      for line in text.components(separatedBy: "\n") {
        consume(line)
      }
      closeCode()
      flush()
      return blocks
    }

    mutating func closeCode() {
      guard let lines = code else { return }
      let body = lines.joined(separator: "\n")
      blocks.append(language == "mermaid" ? .diagram(body) : .code(body))
      code = nil
    }

    mutating func consume(_ line: String) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if var lines = code {
        if trimmed.hasPrefix("```") {
          closeCode()
        } else {
          lines.append(line)
          code = lines
        }
        return
      }
      consumeContent(line, trimmed: trimmed)
    }

    mutating func consumeContent(_ line: String, trimmed: String) {
      if trimmed.hasPrefix("```") {
        flush()
        code = []
        language = trimmed.dropFirst(3).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
      } else if trimmed.isEmpty {
        flush()
      } else if let heading = MarkdownBlock.headingLevel(trimmed) {
        flush()
        blocks.append(
          .heading(heading, String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
      } else if trimmed.hasPrefix("|") {
        appendTableRow(trimmed)
      } else if let item = MarkdownBlock.listItem(line) {
        if !paragraph.isEmpty || !quote.isEmpty || !table.isEmpty {
          let pending = items
          items = []
          flush()
          items = pending
        }
        items.append(item)
      } else if trimmed.hasPrefix(">") {
        if !paragraph.isEmpty || !items.isEmpty || !table.isEmpty { flush() }
        quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
      } else if !items.isEmpty, line.hasPrefix(" ") {
        items[items.count - 1].text += " " + trimmed
      } else {
        if !items.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
        paragraph.append(line)
      }
    }

    mutating func appendTableRow(_ row: String) {
      if !paragraph.isEmpty || !items.isEmpty || !quote.isEmpty { flush() }
      table.append(row)
    }
  }

  /// Pipe rows become a table once the second row is a delimiter row; until then, as while streaming, a paragraph.
  private static func table(_ lines: [String]) -> MarkdownBlock {
    let rows = lines.map(cells)
    guard rows.count >= 2, !rows[1].isEmpty,
      rows[1].allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil })
    else { return .paragraph(lines.joined(separator: "\n")) }
    let columns = rows[0]
    let trailing = Set(rows[1].indices.filter { rows[1][$0].hasSuffix(":") && !rows[1][$0].hasPrefix(":") })
    let body = rows.dropFirst(2).map { row in
      Array((row + Array(repeating: "", count: max(0, columns.count - row.count))).prefix(columns.count))
    }
    return .table(columns: columns, rows: body, trailing: trailing)
  }

  private static func cells(_ line: String) -> [String] {
    var row = Substring(line)
    if row.hasPrefix("|") { row = row.dropFirst() }
    if row.hasSuffix("|") { row = row.dropLast() }
    return row.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func headingLevel(_ line: String) -> Int? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    return hashes
  }

  private static func listItem(_ line: String) -> Item? {
    let indent = line.prefix { $0 == " " }.count / 2
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
      return Item(marker: "•", text: String(trimmed.dropFirst(2)), indent: indent)
    }
    let digits = trimmed.prefix { $0.isNumber }
    if !digits.isEmpty, digits.count <= 3 {
      let rest = trimmed.dropFirst(digits.count)
      if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
        return Item(marker: digits + ".", text: String(rest.dropFirst(2)), indent: indent)
      }
    }
    return nil
  }
}
