import SwiftUI

/// Renders agent replies: headings, lists, quotes, tables, and code blocks, with inline Markdown inside them.
/// Unfinished streaming text renders too; an open code fence simply runs to the end.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text))
        case .heading(let level, let text):
            Text(inline(text)).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }
        case .quote(let text):
            Text(inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
        case .table(let columns, let rows, let trailing):
            DisplayTable(columns: columns, rows: rows, numeric: trailing, markdown: true)
        }
    }

    private func inline(_ text: String) -> AttributedString { inlineMarkdown(text) }
}

func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

enum MarkdownBlock: Equatable {
    struct Item: Equatable {
        var marker: String
        var text: String
        var indent: Int
    }

    case paragraph(String)
    case heading(Int, String)
    case list([Item])
    case quote(String)
    case code(String)
    /// Trailing holds the columns the delimiter row aligns right.
    case table(columns: [String], rows: [[String]], trailing: Set<Int>)

    static func parse(_ text: String) -> [MarkdownBlock] {
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
            if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
            flush()
            return blocks
        }

        mutating func consume(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
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
