import Foundation

/// What choosing a palette item does. Each app decides how to open a page or its settings.
public enum PaletteCommand: Hashable {
  case open(Route)
  case settings
  case newBot
  case newGroupChat
  case theme(AppTheme)
}

public struct PaletteItem: Identifiable, Hashable {
  public let id: String
  public let title: String
  public let symbol: String
  /// A short note at the row's end, such as Paused or Current.
  public let detail: String?
  public let command: PaletteCommand
  fileprivate let terms: [String]

  fileprivate init(
    id: String, title: String, symbol: String, command: PaletteCommand, detail: String? = nil, terms: [String] = []
  ) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.command = command
    self.detail = detail
    self.terms = [title] + terms
  }

  fileprivate func score(_ query: String) -> Int {
    terms.map { CommandPalette.score(query, in: $0) }.max() ?? 0
  }

  fileprivate init(page route: Route, symbol: String, section: String? = nil, terms: [String] = []) {
    self.init(
      id: "page:\(route)", title: route.title, symbol: symbol, command: .open(route),
      terms: terms + (section.map { ["\($0) \(route.title)"] } ?? []))
  }
}

public struct PaletteSection: Identifiable, Hashable {
  public let title: String
  public let items: [PaletteItem]

  public var id: String { title }
}

/// The web's command palette: bots, group chats, what can be created, pages, settings, and themes.
public struct CommandPalette {
  public let sections: [PaletteSection]

  /// `pending` holds the app's in-flight mutation keys: a bot or group being changed can't be opened
  /// from the sidebar either.
  public init(
    bots: [Agent], groups: [GroupChat], pending: Set<String>, isAdmin: Bool, isSignedIn: Bool, theme: AppTheme
  ) {
    let botItems = bots.filter { !pending.contains("agent:\($0.id)") }.map {
      PaletteItem(
        id: "bot:\($0.id)", title: $0.name, symbol: "person.crop.circle", command: .open(.agent($0.id)),
        detail: $0.enabled ? nil : "Paused")
    }
    let groupItems = groups.filter { !pending.contains("group:\($0.id)") && !$0.id.hasPrefix("local:") }.map {
      PaletteItem(id: "group:\($0.id)", title: $0.name, symbol: "person.3", command: .open(.group($0.id)))
    }
    var create: [PaletteItem] = []
    if isSignedIn {
      create.append(.init(id: "new-bot", title: "New bot", symbol: "plus", command: .newBot, terms: ["New agent"]))
      if bots.count >= GroupDraft.memberRange.lowerBound {
        create.append(.init(id: "new-group", title: "New group chat", symbol: "plus", command: .newGroupChat))
      }
    }
    let workspace: [PaletteItem] = [
      .init(page: .memory, symbol: "brain"),
      .init(page: .automations, symbol: "calendar.badge.clock", terms: ["Tasks", "Schedules"]),
      .init(page: .activity, symbol: "waveform.path.ecg")
    ]
    let themes = AppTheme.allCases.map { option in
      PaletteItem(
        id: "theme:\(option.rawValue)", title: "\(option.title) theme", symbol: option.symbol,
        command: .theme(option), detail: option == theme ? "Current" : nil, terms: ["Theme \(option.title)"])
    }
    sections = [
      PaletteSection(title: "Bots", items: botItems),
      PaletteSection(title: "Group chats", items: groupItems),
      PaletteSection(title: "Create", items: create),
      PaletteSection(title: "Workspace", items: workspace),
      PaletteSection(title: "Settings", items: Self.settings(isAdmin: isAdmin)),
      PaletteSection(title: "Theme", items: themes)
    ].filter { !$0.items.isEmpty }
  }

  private static func settings(isAdmin: Bool) -> [PaletteItem] {
    let title = "Settings"
    var items: [PaletteItem] = [
      .init(id: "general", title: "General", symbol: "gearshape", command: .settings, terms: ["Settings General"]),
      .init(page: .providers, symbol: "key.radiowaves.forward", section: title),
      .init(page: .passwordManagers, symbol: "lock.rectangle.stack", section: title),
      .init(page: .webSearch, symbol: "globe", section: title),
      .init(page: .credentials, symbol: "key", section: title),
      .init(page: .logins, symbol: "person.badge.key", section: title),
      .init(page: .judgeModel, symbol: JudgeModelSettings.symbol, section: title),
      .init(page: .visionModel, symbol: VisionModelSettings.symbol, section: title),
      .init(page: .integrations, symbol: "powerplug", section: title),
      .init(page: .coding, symbol: "chevron.left.forwardslash.chevron.right", section: title)
    ]
    if isAdmin { items.append(.init(page: .users, symbol: "person.2", section: title)) }
    items += [
      .init(page: .messageGateways, symbol: "message", section: title),
      .init(page: .eventRelay, symbol: "dot.radiowaves.left.and.right", section: title),
      .init(page: .skills, symbol: "book.closed", section: title)
    ]
    return items
  }

  /// Every section as listed for an empty query. Otherwise only what matches, best match first, so
  /// Return opens what the owner most likely meant.
  public func matching(_ query: String) -> [PaletteSection] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return sections }
    let ranked = sections.compactMap { section -> (section: PaletteSection, best: Int)? in
      let scored = section.items.map { (item: $0, score: $0.score(query)) }.filter { $0.score > 0 }
        .sorted { $0.score > $1.score }
      guard let best = scored.first?.score else { return nil }
      return (PaletteSection(title: section.title, items: scored.map(\.item)), best)
    }
    return ranked.sorted { $0.best > $1.best }.map(\.section)
  }

  /// Higher is better and 0 means no match. Letters in order match too, as on the web.
  static func score(_ query: String, in text: String) -> Int {
    let query = fold(query)
    let text = fold(text)
    if text == query { return 5 }
    if text.hasPrefix(query) { return 4 }
    if text.contains(" " + query) { return 3 }
    if text.contains(query) { return 2 }
    var remaining = query[...]
    for letter in text where letter == remaining.first {
      remaining = remaining.dropFirst()
    }
    return remaining.isEmpty ? 1 : 0
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
