import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A job's whole history as a Markdown file the owner can keep.
public struct JobTranscript: Hashable, Sendable, Transferable {
  public var filename: String
  public var markdown: String

  public static let contentType = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)

  public static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: contentType) { Data($0.markdown.utf8) }
  }

  public init(kind: JobKind, name: String, messages: [Message]) {
    filename = name + ".md"
    let title = kind.noun.prefix(1).uppercased() + kind.noun.dropFirst()
    let sections = ["# \(name)", title] + messages.flatMap(Self.sections)
    markdown = sections.joined(separator: "\n\n") + "\n"
  }

  private static func sections(of message: Message) -> [String] {
    switch message.role {
    case "user":
      ["## Task\n\n\(message.text)"]
    case "toolResult":
      [(message.isError == true ? "Failed:\n\n" : "") + fenced(message.text)]
    case "assistant":
      assistantSections(of: message)
    default:
      []
    }
  }

  private static func assistantSections(of message: Message) -> [String] {
    guard case .array(let blocks)? = message.blocks else {
      return message.text.isEmpty ? [] : [message.text]
    }
    return blocks.compactMap { block in
      switch block["type"]?.stringValue {
      case "text":
        let text = block["text"]?.stringValue ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
      case "toolCall":
        guard let name = block["name"]?.stringValue, !name.isEmpty else { return nil }
        return "### \(name)\n\n\(fenced(json(block["arguments"] ?? .object([:])), info: "json"))"
      default:
        return nil
      }
    }
  }

  private static func json(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
  }

  /// A fence longer than any backtick run in the text, so the text can't close it.
  private static func fenced(_ text: String, info: String = "") -> String {
    var longest = 2
    var run = 0
    for character in text {
      run = character == "`" ? run + 1 : 0
      longest = max(longest, run)
    }
    let fence = String(repeating: "`", count: longest + 1)
    return "\(fence)\(info)\n\(text)\n\(fence)"
  }
}
