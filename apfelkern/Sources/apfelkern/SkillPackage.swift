import Foundation

/// Where an installed skill came from.
public struct SkillOrigin: Codable, Hashable, Sendable {
  /// `owner/repo`.
  public var repository: String
  public var branch: String
  /// The skill's folder; empty for the root.
  public var path: String
  public var commit: String

  public init(repository: String, branch: String, path: String, commit: String) {
    self.repository = repository
    self.branch = branch
    self.path = path
    self.commit = commit
  }

  init(wire: Components.Schemas.SkillOrigin) {
    self.init(repository: wire.repository, branch: wire.branch, path: wire.path, commit: wire.commit)
  }

  public var shortCommit: String { String(commit.prefix(7)) }

  public var folderName: String { path.isEmpty ? repository : repository + "/" + path }

  public var url: URL? {
    URL(string: "https://github.com/" + repository + (path.isEmpty ? "" : "/tree/\(branch)/\(path)"))
  }
}

/// The newer upstream commit of an installed skill.
public struct SkillUpdate: Codable, Hashable, Sendable {
  public var commit: String
  /// The skill's folder is gone from the branch.
  public var removed: Bool

  public init(commit: String, removed: Bool) {
    self.commit = commit
    self.removed = removed
  }

  init(wire: Components.Schemas.SkillUpdate) {
    self.init(commit: wire.commit, removed: wire.removed)
  }

  public var badge: String { removed ? "Removed upstream" : "Update available" }
}

public struct SkillDocument: Hashable, Sendable, Identifiable {
  public var path: String
  public var content: String

  public var id: String { path }

  public init(path: String, content: String) {
    self.path = path
    self.content = content
  }
}

/// A whole skill: `SharedSkill` is the shorter record the list returns.
public struct SkillPackage: Hashable, Sendable {
  public var id: String
  public var name: String
  public var description: String
  public var instructions: String
  public var documents: [SkillDocument]
  public var origin: SkillOrigin?

  public init(
    id: String, name: String, description: String = "", instructions: String, documents: [SkillDocument] = [],
    origin: SkillOrigin? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.instructions = instructions
    self.documents = documents
    self.origin = origin
  }

  init(wire: Components.Schemas.SkillPackage) {
    self.init(
      id: wire.id, name: wire.name, description: wire.description, instructions: wire.instructions,
      documents: wire.documents.map { SkillDocument(path: $0.path, content: $0.content) },
      origin: wire.origin.map(SkillOrigin.init(wire:)))
  }

  var diffLines: [String] {
    skillDiffLines(name: name, description: description, instructions: instructions, documents: documents)
  }
}

/// The upstream version an installed skill would update to.
public struct PendingSkillUpdate: Hashable, Sendable {
  public var commit: String
  public var name: String
  public var description: String
  public var instructions: String
  public var documents: [SkillDocument]
  public var skipped: [String]

  public init(
    commit: String, name: String, description: String, instructions: String, documents: [SkillDocument],
    skipped: [String]
  ) {
    self.commit = commit
    self.name = name
    self.description = description
    self.instructions = instructions
    self.documents = documents
    self.skipped = skipped
  }

  init(wire: Components.Schemas.PendingSkillUpdate) {
    self.init(
      commit: wire.commit, name: wire.name, description: wire.description, instructions: wire.instructions,
      documents: wire.documents.map { SkillDocument(path: $0.path, content: $0.content) }, skipped: wire.skipped)
  }

  var diffLines: [String] {
    skillDiffLines(name: name, description: description, instructions: instructions, documents: documents)
  }
}

public struct SkillCheckFailure: Hashable, Sendable {
  public var repository: String
  public var branch: String
  public var message: String

  public init(repository: String, branch: String, message: String) {
    self.repository = repository
    self.branch = branch
    self.message = message
  }

  public var text: String { "Couldn't check \(repository) (\(branch)): \(message)" }
}

public enum SkillCandidateStatus: String, Hashable, Sendable {
  case new, installed, update, clash, invalid

  init(wire: Components.Schemas.SkillCandidate.StatusPayload) {
    switch wire {
    case .new: self = .new
    case .installed: self = .installed
    case .update: self = .update
    case .clash: self = .clash
    case .invalid: self = .invalid
    }
  }
}

/// A folder with a SKILL.md in a repository, and whether it can be installed.
public struct SkillCandidate: Identifiable, Hashable, Sendable {
  public var path: String
  public var name: String
  public var description: String
  public var status: SkillCandidateStatus
  /// Why a clashing or invalid skill can't be installed.
  public var problem: String?
  /// Files in the folder that won't be imported.
  public var skipped: [String]

  public var id: String { path }

  public init(
    path: String, name: String, description: String = "", status: SkillCandidateStatus, problem: String? = nil,
    skipped: [String] = []
  ) {
    self.path = path
    self.name = name
    self.description = description
    self.status = status
    self.problem = problem
    self.skipped = skipped
  }

  init(wire: Components.Schemas.SkillCandidate) {
    self.init(
      path: wire.path, name: wire.name, description: wire.description,
      status: SkillCandidateStatus(wire: wire.status), problem: wire.problem, skipped: wire.skipped)
  }

  public var isSelectable: Bool { status == .new }

  public var statusLabel: String? {
    switch status {
    case .installed: "Installed"
    case .update: "Update available"
    case .new, .clash, .invalid: nil
    }
  }

  public var note: String? { problem ?? skippedSkillFilesNote(skipped) }
}

public struct SkillListing: Hashable, Sendable {
  public var repository: String
  public var branch: String
  public var commit: String
  public var skills: [SkillCandidate]
  /// Skills beyond the first hundred, not listed.
  public var omitted: Int

  public init(repository: String, branch: String, commit: String, skills: [SkillCandidate], omitted: Int = 0) {
    self.repository = repository
    self.branch = branch
    self.commit = commit
    self.skills = skills
    self.omitted = omitted
  }

  init(wire: Components.Schemas.SkillListing) {
    self.init(
      repository: wire.repository, branch: wire.branch, commit: wire.commit,
      skills: wire.skills.map(SkillCandidate.init(wire:)), omitted: wire.omitted)
  }

  var newPaths: Set<String> { Set(skills.filter(\.isSelectable).map(\.path)) }
}

/// The server's limits on a skill, counted as it counts them: in UTF-16 code units.
public enum SkillLimits {
  public static let nameCharacters = 100
  public static let instructionsCharacters = 32_000

  public static func name(_ text: String) -> String { clamp(text, to: nameCharacters) }

  public static func instructions(_ text: String) -> String { clamp(text, to: instructionsCharacters) }

  static func copyName(_ name: String) -> String { Self.name(name + " copy") }

  private static func clamp(_ text: String, to limit: Int) -> String {
    guard text.utf16.count > limit else { return text }
    var used = 0
    return String(text.prefix { character in
      used += character.utf16.count
      return used <= limit
    })
  }
}

public func skippedSkillFilesNote(_ skipped: [String]) -> String? {
  guard !skipped.isEmpty else { return nil }
  let shown = skipped.prefix(3).joined(separator: ", ")
  return skipped.count > 3 ? "Skips \(shown) and \(skipped.count - 3) more" : "Skips \(shown)"
}
