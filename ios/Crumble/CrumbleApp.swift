import SwiftUI

@main
struct CrumbleApp: App {
  @State private var model = AppModel(
    loadKeychain: ProcessInfo.processInfo.environment["CRUMBLE_SKIP_KEYCHAIN"] != "1")
  @Environment(\.scenePhase) private var scenePhase
  @State private var started = false

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .task {
          guard !started else { return }
          started = true
          Notifier.shared.start(model: model)
          if model.client?.token.isEmpty == false {
            model.refresh()
            model.followActivity()
          }
        }
        .onChange(of: scenePhase) { _, phase in
          guard started else { return }
          if phase == .background { model.suspendStreams() }
          if phase == .active, model.client?.token.isEmpty == false { model.resumeStreams() }
        }
    }
  }
}

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @State private var showingSettings = false
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar

  var body: some View {
    @Bindable var model = model
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      SidebarView(showingSettings: $showingSettings)
        .navigationTitle("Crumble")
    } detail: {
      Group {
        switch model.route {
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
      if route != nil { compactColumn = .detail }
    }
    .sheet(isPresented: $showingSettings) { SettingsView() }
    .sheet(item: $model.agentDraft) {
      AgentEditorView(draft: sheetBinding($model.agentDraft, for: $0))
    }
    .sheet(item: $model.memoryDraft) {
      MemoryFormView(draft: sheetBinding($model.memoryDraft, for: $0))
    }
    .sheet(item: $model.taskDraft) { TaskFormView(draft: sheetBinding($model.taskDraft, for: $0)) }
    .sheet(item: $model.mcpDraft) { MCPFormView(draft: sheetBinding($model.mcpDraft, for: $0)) }
    .sheet(item: $model.skillDraft) {
      SkillFormView(draft: sheetBinding($model.skillDraft, for: $0))
    }
  }
}

func sheetBinding<Draft: Identifiable & Sendable>(_ source: Binding<Draft?>, for item: Draft)
  -> Binding<Draft>
{
  Binding(
    get: { source.wrappedValue ?? item },
    set: { value in
      if source.wrappedValue?.id == item.id { source.wrappedValue = value }
    })
}

struct SidebarView: View {
  @Environment(AppModel.self) private var model
  @Binding var showingSettings: Bool

  private static let workspace: [(Route, String, String)] = [
    (.memory, "Memory", "brain"), (.skills, "Skills", "book.closed"),
    (.tasks, "Tasks", "calendar.badge.clock"), (.activity, "Activity", "waveform.path.ecg"),
    (.integrations, "Integrations", "powerplug"),
  ]

  var body: some View {
    List(selection: Binding(get: { model.route }, set: { model.navigate(to: $0) })) {
      Section("Agents") {
        ForEach(model.agents) { agent in
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
      Section("Workspace") {
        ForEach(Self.workspace, id: \.0) { route, title, symbol in
          NavigationLink(value: route) { Label(title, systemImage: symbol) }
        }
      }
      Section {
        Button("Settings", systemImage: "gearshape") { showingSettings = true }
      }
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
      model.taskDraft == nil, model.mcpDraft == nil, model.skillDraft == nil
    {
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
