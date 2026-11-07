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

/// A phone's navigation stack: the conversation list, then Settings or a chat, then a page.
enum PhonePage: Hashable {
  case settings
  case route(Route)

  var route: Route? {
    if case .route(let route) = self { route } else { nil }
  }

  /// The stack that shows `route`. A page opened from a chat or Settings returns there, and one
  /// opened from nowhere, like a notification, returns through Settings.
  static func path(from current: [PhonePage], to route: Route?) -> [PhonePage] {
    guard let route else { return current.last == .settings ? current : [] }
    if let index = current.firstIndex(of: .route(route)) { return Array(current[...index]) }
    if route.isChat { return [.route(route)] }
    var path = current.isEmpty ? [.settings] : current
    if path.last?.route?.isChat == false { path.removeLast() }
    return path + [.route(route)]
  }
}

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var path: [PhonePage] = []
  @State private var showingPadSettings = false

  private var automationDraft: Binding<AutomationDraft?> {
    let board = model.automationBoard
    return Binding(
      get: { board.draft },
      set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
  }

  private var showingSettings: Binding<Bool> {
    if sizeClass == .compact {
      Binding(
        get: { path.contains(.settings) },
        set: { path = $0 ? [.settings] : [] })
    } else {
      $showingPadSettings
    }
  }

  private var conversationList: some View {
    ConversationListView(showingSettings: showingSettings)
  }

  private func routePage(_ route: Route?) -> some View {
    Group {
      switch route {
      case .group(let id)?:
        if let group = model.groupChats.first(where: { $0.id == id }) {
          GroupChatView(group: group)
        } else {
          ProgressView()
        }
      case .agent(let id)?:
        if let agent = model.agents.first(where: { $0.id == id }) {
          ChatView(agent: agent)
        } else {
          WelcomeView(showingSettings: showingSettings)
        }
      case let panel?:
        PanelView(panel: panel)
      case nil:
        if let agent = model.selectedAgent {
          ChatView(agent: agent)
        } else {
          WelcomeView(showingSettings: showingSettings)
        }
      }
    }
  }

  private var phoneRoot: some View {
    NavigationStack(path: $path) {
      conversationList
        .showsBanners()
        .navigationDestination(for: PhonePage.self) { page in
          Group {
            if let route = page.route { routePage(route) } else { SettingsView() }
          }
          .showsBanners()
        }
    }
    .onChange(of: model.route) { _, route in
      path = PhonePage.path(from: path, to: route)
    }
    .onChange(of: path) { _, pages in
      let route = pages.last?.route
      guard route != model.route else { return }
      if route == nil { model.route = nil } else { model.navigate(to: route) }
    }
  }

  private var padRoot: some View {
    NavigationSplitView {
      conversationList
    } detail: {
      Group {
        if showingPadSettings {
          NavigationStack {
            SettingsView { showingPadSettings = false }
          }
        } else {
          routePage(model.route)
        }
      }
      .showsBanners()
    }
    .onChange(of: model.route) { showingPadSettings = false }
  }

  var body: some View {
    @Bindable var model = model
    Group {
      if sizeClass == .compact { phoneRoot } else { padRoot }
    }
    // On the window, because preferredColorScheme(nil) leaves an open sheet on its old appearance.
    .onChange(of: model.themeBoard.theme, initial: true) { _, theme in
      for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        scene.windows.forEach { $0.overrideUserInterfaceStyle = theme.interfaceStyle }
      }
    }
    .onChange(of: model.route) { old, _ in model.noteChatLeft(old) }
    .fullScreenCover(item: $model.botDesktop) { BotDesktopView(agentID: $0.id) }
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

extension View {
  /// On a page rather than around its stack, where the banner would cover the toolbar's buttons.
  func showsBanners() -> some View {
    overlay(alignment: .top) { ErrorBanner() }
      .overlay(alignment: .bottom) { NoticeToast() }
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
