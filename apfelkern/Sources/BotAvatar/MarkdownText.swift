import apfelkern
import SwiftUI

/// Renders agent replies: headings, lists, quotes, tables, code blocks, and Mermaid diagrams, with inline Markdown.
public struct MarkdownText: View {
  let text: String

  public init(text: String) {
    self.text = text
  }

  private static var spacing: CGFloat {
    #if os(macOS)
      10
    #else
      6
    #endif
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Self.spacing) {
      ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
  }

  @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .paragraph(let text):
      Text(inlineMarkdown(text))
    case .heading(let level, let text):
      Text(inlineMarkdown(text)).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
    case .list(let items):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
            Text(inlineMarkdown(item.text))
          }
          .padding(.leading, CGFloat(item.indent) * 14)
        }
      }
    case .quote(let text):
      Text(inlineMarkdown(text))
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
    case .code(let code):
      CodeBlock(code: code)
    case .diagram(let source):
      DiagramView(source: source)
    case .table(let columns, let rows, let trailing):
      DisplayTable(columns: columns, rows: rows, numeric: trailing, markdown: true)
    }
  }
}

struct CodeBlock: View {
  let code: String

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Text(code).font(.system(.callout, design: .monospaced)).padding(10)
    }
    .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
  }
}

func inlineMarkdown(_ text: String) -> AttributedString {
  let options = AttributedString.MarkdownParsingOptions(
    interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
  return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}
