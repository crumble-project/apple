import apfelkern
import BotAvatar
import SwiftUI

/// The app's root, read like Messages: every bot and group chat together, the latest first.
/// Settings and all the workspace pages sit behind the button in the top corner.
struct ConversationListView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Binding var showingSettings: Bool
  @State private var search = ""
  @State private var searching = false

  private var isConnected: Bool { model.client?.token.isEmpty == false }

  /// Only trouble needs a word under the title; a working connection stays out of the way.
  private var status: String {
    if !isConnected { return "Connect in Settings" }
    if !model.errorText.isEmpty || !model.streamStatus.isEmpty { return "Connection needs attention" }
    return ""
  }

  private func run(_ command: PaletteCommand) {
    search = ""
    searching = false
    switch command {
    case .open(let route): model.navigate(to: route)
    case .settings: showingSettings = true
    case .newBot: model.createAgent()
    case .newGroupChat: model.createGroup()
    case .theme(let theme): model.chooseTheme(theme)
    }
  }

  private func searchRow(_ item: PaletteItem) -> some View {
    Button { run(item.command) } label: {
      HStack(spacing: 12) {
        if case .open(.agent(let id)) = item.command, let agent = model.agents.first(where: { $0.id == id }) {
          BotAvatarView(agent: agent, size: 28, state: model.botState(agent)).accessibilityHidden(true)
        } else {
          Image(systemName: item.symbol).frame(width: 28).accessibilityHidden(true)
        }
        Text(item.title).lineLimit(1)
        Spacer(minLength: 0)
        if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
    }
    .foregroundStyle(.primary)
  }

  private func botRow(_ agent: Agent) -> some View {
    ConversationRow(
      route: .agent(agent.id), title: agent.name,
      preview: preview(agent.lastMessage ?? "").nilIfEmpty ?? "No messages yet",
      paused: !agent.enabled
    ) {
      BotAvatarView(agent: agent, size: conversationAvatarSize, state: model.botState(agent))
    }
    .disabled(model.pendingMutations.contains("agent:\(agent.id)"))
  }

  private var composeMenu: some View {
    Menu("New Conversation", systemImage: "square.and.pencil") {
      Button("New Bot", systemImage: "plus") { model.createAgent() }
      Button("New Group Chat", systemImage: "person.3") { model.createGroup() }
        .disabled(model.agents.count < GroupDraft.memberRange.lowerBound)
    }
    .disabled(!isConnected)
  }

  private var settingsButton: some View {
    Button("Settings", systemImage: "gearshape") { showingSettings = true }
  }

  @ViewBuilder private var emptyState: some View {
    if model.agents.isEmpty, model.groupChats.isEmpty, search.isEmpty {
      ContentUnavailableView {
        Label("A little help, always here.", systemImage: "sparkles")
      } description: {
        Text(
          model.loading
            ? "Opening your workspace…"
            : isConnected
              ? "Create an agent with a purpose, then give it something to do."
              : "Connect to your Crumble server to bring your agents with you.")
      } actions: {
        if !model.loading {
          if isConnected {
            Button("Create an Agent") { model.createAgent() }.buttonStyle(.borderedProminent)
          } else {
            Button("Connect to Server") { showingSettings = true }.buttonStyle(.borderedProminent)
          }
        }
      }
    }
  }

  var body: some View {
    let results = model.commandPalette.matching(search)
    List {
      if search.isEmpty {
        Section {
          ForEach(model.conversations) { conversation in
            switch conversation {
            case .bot(let agent): botRow(agent)
            case .group(let group): GroupRow(group: group)
            }
          }
        }
        .listSectionSeparator(.hidden, edges: .top)
      } else {
        ForEach(results) { section in
          Section(section.title) { ForEach(section.items) { searchRow($0) } }
        }
      }
    }
    .listStyle(.plain)
    .searchable(text: $search, isPresented: $searching, prompt: "Search")
    .overlay {
      if results.isEmpty { ContentUnavailableView.search(text: search) }
    }
    .overlay { emptyState }
    .refreshable { model.refresh() }
    .navigationTitle("Crumble")
    .navigationSubtitle(status)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) { settingsButton }
      if sizeClass == .compact {
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { composeMenu }
      } else {
        ToolbarItem(placement: .primaryAction) { composeMenu }
      }
    }
  }
}

let conversationAvatarSize: CGFloat = 56

/// One conversation: portrait, name, up to two lines of its latest message, and when that was.
struct ConversationRow<Avatar: View>: View {
  @Environment(AppModel.self) private var model
  let route: Route
  let title: String
  let preview: String
  var paused = false
  @ViewBuilder let avatar: Avatar

  private var unread: Bool { model.unread.count(route) > 0 }
  private var date: String? {
    model.conversationSummaries[route]?.date.map { conversationDateLabel($0) }
  }

  var body: some View {
    Button { model.navigate(to: route) } label: {
      HStack(alignment: .center, spacing: 8) {
        Circle()
          .fill(unread ? Color(.systemBlue) : .clear)
          .frame(width: 9, height: 9)
          .accessibilityHidden(true)
        avatar
          .frame(width: conversationAvatarSize, height: conversationAvatarSize, alignment: .topLeading)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.body.weight(.semibold)).lineLimit(1)
            if paused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if let date { Text(date).font(.subheadline).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }
          Text(preview)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: true)
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
      }
    }
    .foregroundStyle(.primary)
    .listRowInsets(.init(top: 8, leading: 6, bottom: 8, trailing: 14))
    .listRowBackground(
      model.route == route && UIDevice.current.userInterfaceIdiom != .phone
        ? Color(.systemGray5) : Color.clear)
    .accessibilityValue(unread ? "Unread" : "")
  }
}
