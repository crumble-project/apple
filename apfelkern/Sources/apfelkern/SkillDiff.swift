import Foundation

public struct SkillDiffLine: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    case same = " "
    case removed = "-"
    case added = "+"
  }

  public var kind: Kind
  public var text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

func skillDiffLines(name: String, description: String, instructions: String, documents: [SkillDocument]) -> [String] {
  ["# " + name, description, ""] + lines(instructions) + documents.flatMap { document in
    ["", "--- " + document.path] + lines(document.content)
  }
}

private func lines(_ text: String) -> [String] {
  text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

/// A line diff that compares only what lies between the common head and tail, since an update
/// usually changes little and the full table grows with the square of the lines.
func skillDiff(before: [String], after: [String]) -> [SkillDiffLine] {
  var head = 0
  while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
  var tail = 0
  while tail < before.count - head, tail < after.count - head,
    before[before.count - 1 - tail] == after[after.count - 1 - tail] {
    tail += 1
  }
  let same = { SkillDiffLine(kind: .same, text: $0) }
  let middle = walkDiff(
    Array(before[head..<(before.count - tail)]), Array(after[head..<(after.count - tail)]))
  return before[..<head].map(same) + middle + before[(before.count - tail)...].map(same)
}

private func walkDiff(_ old: [String], _ new: [String]) -> [SkillDiffLine] {
  let width = new.count + 1
  // Longest common subsequence of old[i...] and new[j...], at i * width + j.
  var table = [Int](repeating: 0, count: (old.count + 1) * width)
  for row in stride(from: old.count - 1, through: 0, by: -1) {
    for column in stride(from: new.count - 1, through: 0, by: -1) {
      table[row * width + column] = old[row] == new[column]
        ? table[(row + 1) * width + column + 1] + 1
        : max(table[(row + 1) * width + column], table[row * width + column + 1])
    }
  }
  var result: [SkillDiffLine] = []
  var row = 0
  var column = 0
  while row < old.count || column < new.count {
    if row < old.count, column < new.count, old[row] == new[column] {
      result.append(SkillDiffLine(kind: .same, text: old[row]))
      row += 1
      column += 1
    } else if row < old.count,
      column == new.count || table[(row + 1) * width + column] >= table[row * width + column + 1] {
      result.append(SkillDiffLine(kind: .removed, text: old[row]))
      row += 1
    } else {
      result.append(SkillDiffLine(kind: .added, text: new[column]))
      column += 1
    }
  }
  return result
}
