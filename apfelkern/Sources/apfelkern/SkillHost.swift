import Foundation

/// The Skills page's actions. Shared skill assignments live on the app model's bots, so this logic
/// runs against the app model and its boards, as `GroupChatHost` does.
@MainActor
public protocol SkillHost: AnyObject {
  var client: APIClient? { get }
  var agents: [Agent] { get set }
  var errorText: String { get set }
  var pendingMutations: Set<String> { get }
  var sharedSkillBoard: SharedSkillBoard { get }
  var skillBulkBoard: SkillBulkBoard { get }
  var botSkillBoard: BotSkillBoard { get }

  /// Reads bots and skills again.
  func reloadSkills()
  func optimisticMutation(
    key: String,
    update: () -> Void,
    rollback: @escaping @MainActor () -> Void,
    work: @escaping @MainActor (APIClient) async throws -> (@MainActor () -> Void)?
  )
}

extension SkillHost {
  public var sharedSkills: [SharedSkill] {
    get { sharedSkillBoard.skills }
    set { sharedSkillBoard.skills = newValue }
  }

  public var skillCatalog: SkillCatalog {
    SkillCatalog(
      skills: sharedSkillBoard.skills, agents: agents, botSkills: botSkillBoard, hidden: skillBulkBoard.hidden,
      scope: sharedSkillBoard.scope, search: sharedSkillBoard.search)
  }

  public func isChangingAssignment(skillID: String, agentID: String) -> Bool {
    pendingMutations.contains(assignmentKey(skillID: skillID, agentID: agentID))
  }

  private func assignmentKey(skillID: String, agentID: String) -> String {
    "agent-shared-skill:\(agentID):\(skillID)"
  }

  /// Only this skill changes on rollback, so assignments to other skills can run beside it.
  public func setSharedSkill(_ skillID: String, for agentID: String, enabled: Bool) {
    guard let agent = agents.first(where: { $0.id == agentID }),
      (agent.sharedSkills ?? []).contains(skillID) != enabled
    else { return }
    let assign = { [self] (assigned: Bool) in
      guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
      var memberships = Set(agents[index].sharedSkills ?? [])
      if assigned { memberships.insert(skillID) } else { memberships.remove(skillID) }
      agents[index].sharedSkills = memberships.sorted()
    }
    optimisticMutation(
      key: assignmentKey(skillID: skillID, agentID: agentID), update: { assign(enabled) },
      rollback: { assign(!enabled) },
      work: { client in
        try await client.assignSharedSkill(skillID, agentID: agentID, assigned: enabled)
        return nil
      })
  }

  /// Takes a skill's assignments to `selected`, applying each at once.
  public func assignSharedSkill(_ skillID: String, usedBy selected: Set<String>) {
    for change in agents.assignmentChanges(skill: skillID, selected: selected) {
      setSharedSkill(skillID, for: change.agentID, enabled: change.enabled)
    }
  }

  /// Returns false when the skill has a write in flight. Assignments follow the save, since a new
  /// skill has no ID to assign before the server confirms it.
  @discardableResult
  public func saveSharedSkill(
    skillID: String?, name: String, instructions: String, usedBy: Set<String>,
    onFailure: @escaping @MainActor (String) -> Void
  ) -> Bool {
    guard let client else {
      errorText = "Connect to your server in Settings."
      return false
    }
    errorText = ""
    return sharedSkillBoard.save(
      skillID: skillID, name: name, instructions: instructions, client: client,
      onSaved: { [self] in assignSharedSkill($0, usedBy: usedBy) }, onFailure: onFailure)
  }

  public func deleteSharedSkill(_ id: String) {
    guard let client else {
      errorText = "Connect to your server in Settings."
      return
    }
    let users = agents.using(skill: id)
    for index in agents.indices where users.contains(agents[index].id) {
      agents[index].sharedSkills?.removeAll { $0 == id }
    }
    sharedSkillBoard.delete(id, client: client) { [self] in
      for index in agents.indices where users.contains(agents[index].id) {
        agents[index].sharedSkills?.append(id)
      }
    }
  }

  public func copySharedSkill(_ skill: SharedSkill) {
    guard let client else { return }
    sharedSkillBoard.copy(skill, client: client)
  }

  public func checkSkillUpdates() {
    guard let client else { return }
    sharedSkillBoard.checkForUpdates(client: client)
  }

  public func openSkillInstall() {
    sharedSkillBoard.sheet = .install(SkillInstall())
  }

  public func openInstalledSkill(_ skill: SharedSkill) {
    guard let client else { return }
    let review = SkillReview(skill: skill, usedBy: agents.using(skill: skill.id))
    review.load(client: client, includingUpdate: false)
    sharedSkillBoard.sheet = .view(review)
  }

  public func openSkillUpdate(_ skill: SharedSkill) {
    guard let client else { return }
    let review = SkillReview(skill: skill)
    review.load(client: client, includingUpdate: true)
    sharedSkillBoard.sheet = .update(review)
  }

  public func findSkills(_ install: SkillInstall) {
    guard let client else { return }
    install.find(client: client)
  }

  public func runSkillInstallAction(_ install: SkillInstall) {
    guard let client else { return }
    guard install.listing != nil else {
      install.find(client: client)
      return
    }
    install.install(board: sharedSkillBoard, client: client) { [self] in reloadSkills() }
  }

  public func applySkillUpdate(_ review: SkillReview) {
    guard let client else { return }
    review.apply(board: sharedSkillBoard, client: client)
  }

  /// `targets` matter for assigning and removing.
  public func runBulkSkillAction(_ action: BulkSkillAction, targets: Set<String> = []) {
    guard let client else { return }
    skillBulkBoard.run(
      action, picked: skillCatalog.picked(skillBulkBoard.selected),
      bots: agents.filter { targets.contains($0.id) }.map { BulkSkillBot(id: $0.id, name: $0.name) }, client: client,
      deleted: { [self] in
        sharedSkillBoard.forget($0)
        botSkillBoard.forget($0)
      },
      finished: { [self] in reloadSkills() })
  }
}
