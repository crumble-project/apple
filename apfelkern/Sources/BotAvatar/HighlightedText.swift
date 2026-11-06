import apfelkern
import SwiftUI

/// Text with every match of a search marked, as the web's memory rows do.
public struct HighlightedText: View {
  private let text: String
  private let query: String

  public init(_ text: String, query: String) {
    self.text = text
    self.query = query
  }

  public var body: some View { Text(marked) }

  private var marked: AttributedString {
    var marked = AttributedString(text)
    for match in searchMatches(of: query, in: text) {
      guard let range = Range(match, in: marked) else { continue }
      marked[range].backgroundColor = .yellow.opacity(0.4)
    }
    return marked
  }
}

/// Where a memory came from and how long ago it changed, under its text.
public struct MemorySourceLine: View {
  private let memory: Memory

  public init(memory: Memory) {
    self.memory = memory
  }

  public var body: some View {
    if let line = memoryLine(memory) {
      HStack(spacing: 4) {
        if let symbol = memorySourceSymbol(memory.source) { Image(systemName: symbol) }
        Text(line)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
