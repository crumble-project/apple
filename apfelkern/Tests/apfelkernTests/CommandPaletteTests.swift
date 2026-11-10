import Testing
@testable import apfelkern

private func palette(
  bots: [Agent] = [Agent(id: "b1", name: "Atlas"), Agent(id: "b2", name: "Juniper", enabled: false)],
  groups: [GroupChat] = [], pending: Set<String> = [], isSignedIn: Bool = true,
  theme: AppTheme = .system
) -> CommandPalette {
  CommandPalette(
    bots: bots, groups: groups, pending: pending, isSignedIn: isSignedIn, theme: theme)
}

private func group(_ id: String, _ name: String = "Trip") -> GroupChat {
  GroupChat(id: id, name: name, memberIds: [], createdAt: "now", updatedAt: "now")
}

private func titles(_ sections: [PaletteSection], in section: String) -> [String] {
  sections.first { $0.title == section }?.items.map(\.title) ?? []
}

@Test func listsTheWebsSectionsInItsOrder() {
  let sections = palette(groups: [group("g1")]).sections
  #expect(sections.map(\.title) == ["Bots", "Group chats", "Create", "Workspace", "Settings", "Theme"])
  #expect(titles(sections, in: "Create") == ["New bot", "New group chat"])
  #expect(titles(sections, in: "Theme") == ["System theme", "Light theme", "Dark theme"])
  #expect(titles(sections, in: "Settings").first == "General")
  #expect(sections.first?.items.last?.detail == "Paused")
}

@Test func serverSettingsAreLeftToTheWeb() {
  #expect(titles(palette().sections, in: "Settings") == ["General", "Skills"])
}

@Test func aGroupChatNeedsTwoBots() {
  #expect(titles(palette(bots: [Agent(id: "b1", name: "Atlas")]).sections, in: "Create") == ["New bot"])
}

@Test func nothingCanBeCreatedWhileSignedOut() {
  #expect(!palette(isSignedIn: false).sections.map(\.title).contains("Create"))
}

@Test func marksTheCurrentTheme() {
  let themes = palette(theme: .dark).sections.first { $0.title == "Theme" }?.items ?? []
  #expect(themes.map(\.detail) == [nil, nil, "Current"])
}

@Test func leavesOutWhatTheSidebarDisables() {
  let sections = palette(groups: [group("local:1"), group("g1", "Kept"), group("g2", "Gone")],
                         pending: ["agent:b1", "group:g2"]).sections
  #expect(titles(sections, in: "Bots") == ["Juniper"])
  #expect(titles(sections, in: "Group chats") == ["Kept"])
}

@Test func anEmptyQueryKeepsEverything() {
  let list = palette()
  #expect(list.matching("  ") == list.sections)
}

@Test func theBestMatchComesFirst() {
  let sections = palette().matching("skills")
  #expect(sections.first?.items.first?.command == .open(.skills))
}

@Test func sectionNamesMatchTheirItems() {
  #expect(titles(palette().matching("theme"), in: "Theme").count == 3)
  #expect(titles(palette().matching("dark"), in: "Theme") == ["Dark theme"])
}

@Test func theGlossaryWordFindsTheAppsPage() {
  #expect(palette().matching("automations").first?.items.first?.command == .open(.automations))
}

@Test func lettersInOrderMatchAndCaseAndAccentsDont() {
  #expect(titles(palette().matching("jnpr"), in: "Bots") == ["Juniper"])
  #expect(titles(palette().matching("ÁTLAS"), in: "Bots") == ["Atlas"])
  #expect(palette().matching("zzzz").isEmpty)
}
