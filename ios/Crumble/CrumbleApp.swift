import apfelkern
import BotAvatar
import SwiftUI
import UniformTypeIdentifiers

@main
struct CrumbleApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel(
    loadKeychain: ProcessInfo.processInfo.environment["CRUMBLE_SKIP_KEYCHAIN"] != "1")
  @Environment(\.scenePhase) private var scenePhase
  @State private var started = false

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .environment(\.diagramServer, URL(string: model.serverURL))
        .task {
          guard !started else { return }
          started = true
          Notifier.shared.start(model: model)
          model.showUnreadBadge()
          if model.client?.token.isEmpty == false {
            model.refresh()
            model.followActivity()
          }
        }
        .onChange(of: model.route) { _, _ in
          Notifier.shared.updatePresence()
          model.markChatSeen()
        }
        .onChange(of: scenePhase) { _, phase in
          guard started else { return }
          if phase == .background {
            Notifier.shared.updatePresence(active: false)
            model.suspendStreams()
          }
          if phase == .active {
            Notifier.shared.refreshAuthorization()
            Notifier.shared.updatePresence(active: true)
            model.markChatSeen()
            if model.client?.token.isEmpty == false { model.resumeStreams() }
          }
        }
    }
  }
}

extension AppTheme {
  fileprivate var interfaceStyle: UIUserInterfaceStyle {
    switch self {
    case .system: .unspecified
    case .light: .light
    case .dark: .dark
    }
  }
}

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var showingSettings = false

  private var automationDraft: Binding<AutomationDraft?> {
    let board = model.automationBoard
    return Binding(
      get: { board.draft },
      set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
  }

  var body: some View {
    @Bindable var model = model
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      SidebarView(showingSettings: $showingSettings, compactColumn: $compactColumn)
        .navigationTitle("Crumble")
    } detail: {
      Group {
        switch model.route {
        case .group?:
          if let group = model.selectedGroup {
            GroupChatView(group: group)
          } else {
            ProgressView()
          }
        case .agent?, nil:
          if let agent = model.selectedAgent {
            ChatView(agent: agent)
          } else {
            WelcomeView(showingSettings: $showingSettings)
          }
        case let panel?:
          PanelView(panel: panel)
        }
      }
      .overlay(alignment: .top) { ErrorBanner() }
      .overlay(alignment: .bottom) { NoticeToast() }
    }
    .onChange(of: model.route) { _, route in
      compactColumn = route == nil ? .sidebar : .detail
    }
    // On the window, because preferredColorScheme(nil) leaves an open sheet on its old appearance.
    .onChange(of: model.themeBoard.theme, initial: true) { _, theme in
      for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        scene.windows.forEach { $0.overrideUserInterfaceStyle = theme.interfaceStyle }
      }
    }
    .fullScreenCover(item: $model.botDesktop) { BotDesktopView(agentID: $0.id) }
    .sheet(isPresented: $showingSettings) { SettingsView() }
    .sheet(item: $model.agentDraft) {
      AgentEditorView(draft: sheetBinding($model.agentDraft, for: $0))
    }
    .botSecretSheets(active: model.agentDraft == nil)
    .sheet(item: $model.memoryDraft) {
      MemoryFormView(draft: sheetBinding($model.memoryDraft, for: $0))
    }
    .sheet(item: automationDraft) { AutomationFormView(draft: sheetBinding(automationDraft, for: $0)) }
    .sheet(item: $model.mcpDraft) { MCPFormView(draft: sheetBinding($model.mcpDraft, for: $0)) }
    .machineAccountSheet()
    .adminSheets()
    .messageGatewaySheet()
    .pluginSettingSheet(active: model.connectedServices.gateways.draft == nil)
    .gitHubAppSheets()
    .skillSheet(active: model.agentDraft == nil)
    .sheet(item: $model.jobHistory) { JobSheet(job: $0) }
    .sheet(item: $model.groupDraft) { GroupEditorView(draft: sheetBinding($model.groupDraft, for: $0)) }
  }
}

/// For credentials. Universal Clipboard would hand the text to the owner's other devices.
func copyLocally(_ text: String) {
  UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: [.localOnly: true])
}

func sheetBinding<Draft: Identifiable & Sendable>(_ source: Binding<Draft?>, for item: Draft)
  -> Binding<Draft> {
  Binding(
    get: { source.wrappedValue ?? item },
    set: { value in
      if source.wrappedValue?.id == item.id { source.wrappedValue = value }
    })
}

struct SidebarView: View {
  private var groupsSection: some View {
    Section {
      ForEach(model.groupChats) { GroupRow(group: $0) }
      if model.groupChats.isEmpty {
        Text(
          model.agents.count < GroupDraft.memberRange.lowerBound
            ? "Create two bots to start a group chat" : "No group chats yet"
        )
        .foregroundStyle(.secondary)
      }
    } header: {
      HStack {
        Text("Group Chats")
        Spacer()
        Button("New Group Chat", systemImage: "plus") { model.createGroup() }
          .labelStyle(.iconOnly)
          .disabled(model.agents.count < GroupDraft.memberRange.lowerBound)
      }
    }
  }

  private func agentRow(_ agent: Agent) -> some View {
    NavigationLink(value: Route.agent(agent.id)) {
      HStack(spacing: 12) {
        BotAvatarView(agent: agent, size: 44, state: model.botState(agent))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(agent.name).font(.headline).lineLimit(1)
            if !agent.enabled { Text("Paused").font(.caption).foregroundStyle(.secondary) }
          }
          Text(preview(agent.lastMessage ?? "").nilIfEmpty ?? "No messages yet")
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      .padding(.vertical, 4)
    }
    .disabled(model.pendingMutations.contains("agent:\(agent.id)"))
  }

  @Environment(AppModel.self) private var model
  @Binding var showingSettings: Bool
  @Binding var compactColumn: NavigationSplitViewColumn
  @State private var search = ""
  @State private var searching = false

  private struct WorkspaceDestination {
    let route: Route
    let title: String
    let symbol: String
  }

  private static let workspace: [WorkspaceDestination] = [
    .init(route: .memory, title: "Memory", symbol: "brain"),
    .init(route: .skills, title: "Skills", symbol: "book.closed"),
    .init(route: .automations, title: "Automations", symbol: "calendar.badge.clock"),
    .init(route: .activity, title: "Activity", symbol: "waveform.path.ecg"),
    .init(route: .avatars, title: "Avatars", symbol: "face.smiling"),
    .init(route: .judgeModel, title: JudgeModelSettings.title, symbol: JudgeModelSettings.symbol),
    .init(route: .visionModel, title: VisionModelSettings.title, symbol: VisionModelSettings.symbol),
    .init(route: .integrations, title: "Integrations", symbol: "powerplug"),
    .init(route: .coding, title: "Coding", symbol: "chevron.left.forwardslash.chevron.right"),
    .init(route: .users, title: "Users", symbol: "person.2")
  ]

  private static let connectedServices: [WorkspaceDestination] = [
    .init(route: .providers, title: "Providers", symbol: "key.radiowaves.forward"),
    .init(route: .passwordManagers, title: "Password managers", symbol: "lock.rectangle.stack"),
    .init(route: .credentials, title: "Credentials", symbol: "key"),
    .init(route: .logins, title: "Logins", symbol: "person.badge.key"),
    .init(route: .webSearch, title: "Web search", symbol: "globe"),
    .init(route: .messageGateways, title: "Message gateways", symbol: "message"),
    .init(route: .eventRelay, title: "Event relay", symbol: "dot.radiowaves.left.and.right")
  ]

  private func run(_ command: PaletteCommand) {
    search = ""
    searching = false
    switch command {
    case .open(let route):
      model.navigate(to: route)
      compactColumn = .detail
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

  @ViewBuilder private var sidebarSections: some View {
    Section("Agents") {
      ForEach(model.agents) { agent in
        agentRow(agent)
      }
      if model.agents.isEmpty {
        Text(model.loading ? "Opening your workspace…" : "Your agents will appear here.")
          .foregroundStyle(.secondary)
        if model.client?.token.isEmpty != false {
          Button("Connect to your server", systemImage: "network") { showingSettings = true }
        } else {
          Button("Create an Agent", systemImage: "plus") { model.createAgent() }
        }
      }
    }
    groupsSection
    Section("Workspace") {
      ForEach(Self.workspace.filter { $0.route != .users || model.adminBoard.isAdmin }, id: \.route) { item in
        NavigationLink(value: item.route) { Label(item.title, systemImage: item.symbol) }
      }
    }
    Section("Connected services") {
      ForEach(Self.connectedServices, id: \.route) { item in
        NavigationLink(value: item.route) { Label(item.title, systemImage: item.symbol) }
      }
    }
    Section {
      Button("Settings", systemImage: "gearshape") { showingSettings = true }
    }
  }

  var body: some View {
    let results = model.commandPalette.matching(search)
    List(selection: Binding(get: { model.route }, set: { model.navigate(to: $0) })) {
      if search.isEmpty {
        sidebarSections
      } else {
        ForEach(results) { section in
          Section(section.title) { ForEach(section.items) { searchRow($0) } }
        }
      }
    }
    .searchable(text: $search, isPresented: $searching, prompt: "Search chats, pages, and settings")
    .overlay {
      if results.isEmpty { ContentUnavailableView.search(text: search) }
    }
    .refreshable { model.refresh() }
    .toolbar {
      ToolbarItem(placement: .largeTitle) {
        HStack(spacing: 10) {
          Text("Crumble").font(.largeTitle.bold())
          ConnectionStatus()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
      }
      .sharedBackgroundVisibility(.hidden)
      ToolbarItem(placement: .primaryAction) {
        Button("New Agent", systemImage: "square.and.pencil") { model.createAgent() }
          .disabled(model.client?.token.isEmpty != false)
      }
    }
  }
}

struct ConnectionStatus: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let (status, color): (String, Color) =
      if model.client?.token.isEmpty != false {
        ("Connect in Settings", .secondary)
      } else if !model.errorText.isEmpty || !model.streamStatus.isEmpty {
        ("Connection needs attention", .orange)
      } else if model.loading { ("Syncing…", .secondary) } else { ("Connected", .green) }
    Circle().fill(color).frame(width: 8, height: 8)
      .accessibilityLabel(status)
      .help(status)
  }
}

struct WelcomeView: View {
  @Environment(AppModel.self) private var model
  @Binding var showingSettings: Bool

  var body: some View {
    if model.loading && model.agents.isEmpty {
      ProgressView("Opening your workspace")
    } else {
      ContentUnavailableView {
        Label("A little help, always here.", systemImage: "sparkles")
      } description: {
        Text(
          model.client?.token.isEmpty != false
            ? "Connect to your Crumble server to bring your agents with you."
            : "Create an agent with a purpose, then give it something to do.")
      } actions: {
        if model.client?.token.isEmpty != false {
          Button("Connect to Server") { showingSettings = true }.buttonStyle(.borderedProminent)
        } else {
          Button("Create an Agent") { model.createAgent() }.buttonStyle(.borderedProminent)
        }
      }
    }
  }
}

struct ErrorBanner: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    if !model.errorText.isEmpty, model.agentDraft == nil, model.memoryDraft == nil,
      model.automationBoard.draft == nil, model.mcpDraft == nil, model.skillDraft == nil, model.groupDraft == nil {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        Text(model.errorText).font(.callout).textSelection(.enabled)
        Spacer(minLength: 0)
        Button("Dismiss", systemImage: "xmark") { model.errorText = "" }
          .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
      }
      .padding(12)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      .padding(12)
    }
  }
}

struct NoticeToast: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    if !model.notice.isEmpty {
      Text(model.notice).font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 90)
        .accessibilityAddTraits(.updatesFrequently)
    }
  }
}

struct SheetError: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    if !model.errorText.isEmpty {
      Section {
        Label(model.errorText, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red).textSelection(.enabled)
      }
    }
  }
}
