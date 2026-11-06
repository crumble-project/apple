import Foundation
import Observation

/// The sheets of the Skills page that work on installed skills.
public enum SharedSkillSheet: Identifiable {
  case install(SkillInstall)
  case view(SkillReview)
  case update(SkillReview)

  public var id: UUID {
    switch self {
    case .install(let install): install.id
    case .view(let review), .update(let review): review.id
    }
  }
}

/// The shared and default skills. Saves, copies, and deletes apply at once; a failure takes them
/// back. Updates and checks depend on GitHub, so they show as pending until the server answers.
@MainActor @Observable
public final class SharedSkillBoard {
  public var skills: [SharedSkill] = []
  public private(set) var readError: String?
  /// Skills with a write in flight. One at a time, so a late answer can't undo a newer edit.
  public private(set) var pending: Set<String> = []
  /// Why deleting or copying failed, or why a sheet's request did after the owner left that sheet.
  public private(set) var error: String?
  public private(set) var checking = false
  public private(set) var checkFailures: [String] = []
  public var sheet: SharedSkillSheet?
  public var scope = SkillScope.all
  public var search = ""
  private var reads = 0
  /// Reads up to this one are ignored: they may predate a write.
  private var settledRead = 0
  private var writes = 0
  private(set) var generation = 0

  public init() {}

  public func reset() {
    generation += 1
    skills = []
    readError = nil
    pending = []
    error = nil
    checking = false
    checkFailures = []
    sheet = nil
    scope = .all
    search = ""
    reads = 0
    settledRead = 0
    writes = 0
  }

  public func skill(_ id: String) -> SharedSkill? { skills.first { $0.id == id } }

  /// The owner may have opened another sheet while this one's request ran.
  func close(sheet id: UUID) {
    if sheet?.id == id { sheet = nil }
  }

  /// The page is the only place left to say why, once the sheet is gone.
  func report(_ message: String, fromSheet id: UUID) {
    if sheet?.id != id { error = message }
  }

  /// While a write runs this waits: the write reads the list again when it ends.
  public func refresh(client: APIClient) {
    guard writes == 0 else { return }
    let version = generation
    reads += 1
    let read = reads
    Task {
      do {
        let loaded = try await client.sharedSkills()
        guard generation == version, read > settledRead else { return }
        settledRead = read
        skills = loaded
        readError = nil
      } catch {
        guard generation == version, read > settledRead else { return }
        readError = friendlyError(error)
      }
    }
  }

  /// Creates a skill when `skillID` is nil. Returns false when that skill has a write in flight.
  /// `onSaved` gets the saved skill's ID. `onFailure` runs after the rollback, so the app can give
  /// the owner their draft back.
  @discardableResult
  public func save(
    skillID: String? = nil, name: String, instructions: String, client: APIClient,
    onSaved: @escaping @MainActor (String) -> Void, onFailure: @escaping @MainActor (String) -> Void
  ) -> Bool {
    guard let skillID else {
      create(
        SharedSkill(
          id: "pending-skill-" + UUID().uuidString, name: name, instructions: instructions, source: "shared"),
        client: client, onSaved: onSaved, onFailure: onFailure,
        work: { try await $0.createSharedSkill(name: name, instructions: instructions) })
      return true
    }
    guard let old = skill(skillID), !pending.contains(skillID) else { return false }
    var edited = old
    edited.name = name
    edited.instructions = instructions
    replace(skillID, with: edited)
    write(
      skillID, client: client, rollback: { [self] in replace(skillID, with: old) }, onFailure: onFailure,
      work: { client in
        _ = try await client.updateSharedSkill(skillID, name: name, instructions: instructions)
        return { onSaved(skillID) }
      })
    return true
  }

  /// Copies a skill with its description and reference documents as an editable shared skill.
  public func copy(_ skill: SharedSkill, client: APIClient) {
    let provisional = SharedSkill(
      id: "pending-skill-" + UUID().uuidString, name: SkillLimits.copyName(skill.name),
      instructions: skill.instructions, source: "shared", description: skill.description)
    create(provisional, client: client, onSaved: { _ in }, onFailure: nil, work: { client in
      let full = try await client.sharedSkill(skill.id)
      return try await client.createSharedSkill(
        name: SkillLimits.copyName(full.name), description: full.description, instructions: full.instructions,
        documents: full.documents)
    })
  }

  private func create(
    _ provisional: SharedSkill, client: APIClient, onSaved: @escaping @MainActor (String) -> Void,
    onFailure: (@MainActor (String) -> Void)?,
    work: @escaping @MainActor (APIClient) async throws -> SharedSkill
  ) {
    skills.append(provisional)
    write(
      provisional.id, client: client, rollback: { [self] in skills.removeAll { $0.id == provisional.id } },
      onFailure: onFailure,
      work: { [self] client in
        let saved = try await work(client)
        return { [self] in
          replace(provisional.id, with: saved)
          onSaved(saved.id)
        }
      })
  }

  /// `onFailure` runs after the skill is back, so the app can restore what it took out with it.
  public func delete(_ id: String, client: APIClient, onFailure: @escaping @MainActor () -> Void) {
    guard !pending.contains(id), let index = skills.firstIndex(where: { $0.id == id }) else { return }
    let old = skills.remove(at: index)
    write(
      id, client: client,
      rollback: { [self] in
        skills.insert(old, at: min(index, skills.count))
        onFailure()
      },
      work: { client in
        try await client.deleteSharedSkill(id)
        return {}
      })
  }

  /// Takes skills a bulk action already deleted out of the list, ignoring reads that predate it.
  func forget(_ ids: Set<String>) {
    skills.removeAll { ids.contains($0.id) }
    settledRead = reads
  }

  func applyUpdate(
    _ id: String, client: APIClient, onDone: @escaping @MainActor () -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) {
    guard !pending.contains(id) else { return }
    write(
      id, client: client, rollback: {}, onFailure: onFailure,
      work: { [self] client in
        let updated = try await client.applySkillUpdate(id)
        return { [self] in
          if var current = skill(id) {
            current.name = updated.name
            current.description = updated.description
            current.instructions = updated.instructions
            current.origin = updated.origin
            current.update = nil
            replace(id, with: current)
          }
          onDone()
        }
      })
  }

  public func checkForUpdates(client: APIClient) {
    guard !checking else { return }
    let version = generation
    checking = true
    checkFailures = []
    Task {
      do {
        let failures = try await client.checkSkillUpdates()
        guard generation == version else { return }
        checkFailures = failures.map(\.text)
      } catch {
        guard generation == version else { return }
        checkFailures = [friendlyError(error)]
      }
      checking = false
      refresh(client: client)
    }
  }

  private func replace(_ id: String, with skill: SharedSkill) {
    guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
    skills[index] = skill
  }

  private func write(
    _ id: String, client: APIClient, rollback: @escaping @MainActor () -> Void,
    onFailure: (@MainActor (String) -> Void)? = nil,
    work: @escaping @MainActor (APIClient) async throws -> @MainActor () -> Void
  ) {
    let version = generation
    pending.insert(id)
    writes += 1
    settledRead = reads
    error = nil
    Task {
      do {
        let confirm = try await work(client)
        guard generation == version else { return }
        confirm()
      } catch {
        guard generation == version else { return }
        rollback()
        let message = friendlyError(error)
        if let onFailure { onFailure(message) } else { self.error = message }
      }
      pending.remove(id)
      writes -= 1
      refresh(client: client)
    }
  }
}

/// The Install from GitHub sheet. Installing reads the repository again, so the sheet stays until
/// the server answers. An answer for a repository the owner has since changed is dropped.
@MainActor @Observable
public final class SkillInstall: Identifiable {
  public let id = UUID()
  public private(set) var location = ""
  public private(set) var listing: SkillListing?
  public private(set) var picked: Set<String> = []
  public var botIDs: Set<String> = []
  public private(set) var browsing = false
  public private(set) var installing = false
  public private(set) var error: String?
  private var search = 0

  public init() {}

  public func setLocation(_ location: String) {
    guard location != self.location else { return }
    self.location = location
    search += 1
    listing = nil
    picked = []
    browsing = false
    error = nil
  }

  public func toggle(_ path: String, isOn: Bool) {
    if isOn { picked.insert(path) } else { picked.remove(path) }
  }

  public func find(client: APIClient) {
    let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !location.isEmpty, !installing else { return }
    search += 1
    let current = search
    browsing = true
    error = nil
    Task {
      do {
        let found = try await client.browseSkillRepository(location: location)
        guard search == current else { return }
        listing = found
        picked = found.newPaths
      } catch {
        guard search == current else { return }
        listing = nil
        picked = []
        self.error = friendlyError(error)
      }
      browsing = false
    }
  }

  public var actionLabel: String {
    guard listing != nil else { return "Find skills" }
    return "Install \(picked.count) \(picked.count == 1 ? "skill" : "skills")"
  }

  public var actionReady: Bool {
    guard !browsing, !installing else { return false }
    return listing == nil ? !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !picked.isEmpty
  }

  func install(board: SharedSkillBoard, client: APIClient, onInstalled: @escaping @MainActor () -> Void) {
    guard let listing, actionReady else { return }
    let paths = listing.skills.map(\.path).filter(picked.contains)
    let version = board.generation
    installing = true
    error = nil
    Task {
      defer { installing = false }
      do {
        try await client.installSkills(from: listing, paths: paths, botIDs: botIDs.sorted())
        guard board.generation == version else { return }
        board.close(sheet: id)
        onInstalled()
      } catch {
        guard board.generation == version else { return }
        let message = friendlyError(error)
        self.error = message
        board.report(message, fromSheet: id)
      }
    }
  }
}

/// An installed skill in the view or update sheet.
@MainActor @Observable
public final class SkillReview: Identifiable {
  public let id = UUID()
  public let skill: SharedSkill
  public private(set) var package: SkillPackage?
  public private(set) var pendingUpdate: PendingSkillUpdate?
  public private(set) var diff: [SkillDiffLine]?
  public private(set) var applying = false
  public private(set) var error: String?
  public var usedBy: Set<String>

  public init(skill: SharedSkill, usedBy: Set<String> = []) {
    self.skill = skill
    self.usedBy = usedBy
  }

  public var skippedNote: String? { pendingUpdate.flatMap { skippedSkillFilesNote($0.skipped) } }

  func load(client: APIClient, includingUpdate: Bool) {
    let skillID = skill.id
    Task {
      do {
        async let full = client.sharedSkill(skillID)
        async let upstream = includingUpdate ? client.pendingSkillUpdate(skillID) : nil
        let (package, pendingUpdate) = try await (full, upstream)
        self.package = package
        self.pendingUpdate = pendingUpdate
        if let pendingUpdate { diff = skillDiff(before: package.diffLines, after: pendingUpdate.diffLines) }
      } catch {
        self.error = friendlyError(error)
      }
    }
  }

  func apply(board: SharedSkillBoard, client: APIClient) {
    guard pendingUpdate != nil, !applying, !board.pending.contains(skill.id) else { return }
    applying = true
    error = nil
    board.applyUpdate(
      skill.id, client: client,
      onDone: { [self] in
        applying = false
        board.close(sheet: id)
      },
      onFailure: { [self] message in
        applying = false
        error = message
        board.report(message, fromSheet: id)
      })
  }
}
