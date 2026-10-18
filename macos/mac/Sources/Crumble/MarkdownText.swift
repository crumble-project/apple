import SwiftUI

/// Renders agent replies: headings, lists, quotes, and code blocks, with inline Markdown inside them.
/// Unfinished streaming text renders too; an open code fence simply runs to the end.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
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

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [Item] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !items.isEmpty { blocks.append(.list(items)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            paragraph = []
            items = []
            quote = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
            } else if trimmed.isEmpty {
                flush()
            } else if let heading = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(heading, String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if let item = listItem(line) {
                if !paragraph.isEmpty || !quote.isEmpty {
                    let pending = items
                    items = []
                    flush()
                    items = pending
                }
                items.append(item)
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !items.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !items.isEmpty, line.hasPrefix(" ") {
                items[items.count - 1].text += " " + trimmed
            } else {
                if !items.isEmpty || !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
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
