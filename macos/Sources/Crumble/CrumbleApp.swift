import apfelkern
import AppKit
import BotAvatar
import SwiftUI

@main
struct CrumbleApp: App {
    @NSApplicationDelegateAdaptor(CrumbleAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // Started from `swift run` there is no bundle telling AppKit this is a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
        Notifier.shared.installDelegate()
    }

    var body: some Scene {
        Window("Crumble", id: "main") {
            ContentView()
                .environment(model)
                .environment(\.diagramServer, URL(string: model.serverURL))
                .frame(minWidth: 860, minHeight: 560)
                .task { model.start() }
                .modifier(FollowsTheme(board: model.themeBoard))
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Agent") { model.createAgent() }.keyboardShortcut("n")
                Button("New Group Chat") { model.createGroup() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                CommandPaletteButton(model: model).keyboardShortcut("k")
            }
            CommandGroup(replacing: .appSettings) { SettingsButton().keyboardShortcut(",") }
            #if DEBUG
                SampleJobCommands(model: model)
            #endif
        }

        // A plain window rather than a Settings scene: those lay their toolbar out as a row of tabs
        // under the title, which leaves a split view with an empty band across the top.
        Window("Settings", id: SettingsButton.windowID) {
            SettingsView().environment(model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 680)

        WindowGroup("Bot Desktop", id: BotDesktopView.windowID, for: String.self) { $agentID in
            if let agentID {
                BotDesktopView(agentID: agentID).environment(model)
            }
        }
        .defaultSize(width: 1280, height: 860)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
                .overlay(alignment: .top) { ErrorBanner() }
                .overlay(alignment: .bottom) { NoticeToast() }
        }
        .overlay {
            if model.commandPaletteOpen { CommandPaletteView() }
        }
        .onAppear {
            model.notifier.openBotDesktop = { openWindow(id: BotDesktopView.windowID, value: $0) }
            model.notifier.openMainWindow = { openWindow(id: "main") }
        }
        .onChange(of: model.route) { model.markChatSeen() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.markChatSeen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            model.markChatSeen()
        }
        .sheet(item: $model.agentDraft) { AgentEditorView(draft: sheetBinding($model.agentDraft, for: $0)) }
        .botSecretSheets(active: model.agentDraft == nil)
        .automationSheet(active: model.agentDraft == nil && !model.settingsShowsAutomations)
        .sheet(item: $model.jobSheet) { JobSheet(job: $0) }
        .sheet(item: $model.groupDraft) { GroupEditorView(draft: sheetBinding($model.groupDraft, for: $0)) }
    }

    @ViewBuilder private var detail: some View {
        if let group = model.selectedGroup {
            GroupChatView(group: group)
        } else if let agent = model.selectedAgent {
            ChatView(agent: agent)
        } else {
            WelcomeView()
        }
    }
}

/// Binds a sheet to the draft it edits. A closing sheet still redraws after Cancel or Save clears
/// the draft, so reads fall back to the sheet's own item and writes to a cleared draft are dropped.
func sheetBinding<Draft: Identifiable & Sendable>(_ source: Binding<Draft?>, for item: Draft) -> Binding<Draft> {
    Binding(
        get: { source.wrappedValue ?? item },
        set: { value in
            if source.wrappedValue?.id == item.id { source.wrappedValue = value }
        }
    )
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.route }, set: { model.navigate(to: $0) })) {
            // One list: a group's stacked avatars already set it apart from a bot.
            ForEach(model.agents) { agent in
                AgentRow(agent: agent)
                    .tag(Route.agent(agent.id))
                    .disabled(model.pendingMutations.contains("agent:\(agent.id)"))
            }
            ForEach(model.groupChats) { group in
                GroupRow(group: group)
                    .tag(Route.group(group.id))
                    .disabled(model.pendingMutations.contains("group:\(group.id)") || group.id.hasPrefix("local:"))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .overlay {
            if model.agents.isEmpty && !model.loading {
                Text("No agents yet").foregroundStyle(.secondary)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button("Search", systemImage: "magnifyingglass") { model.commandPaletteOpen = true }
                    .help("Search (⌘K)")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                // A click makes a bot; holding it offers a group chat too.
                Menu {
                    Button("New Agent") { model.createAgent() }
                    Button("New Group Chat") { model.createGroup() }
                        .disabled(model.agents.count < GroupDraft.memberRange.lowerBound)
                } label: {
                    Label("New Agent", systemImage: "plus")
                } primaryAction: {
                    model.createAgent()
                }
                .menuIndicator(.hidden)
                .help("New Agent (⌘N). Hold for a group chat (⇧⌘N).")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountFooter() }
    }
}

/// Who is signed in, how the connection is doing, and the way to Settings.
struct AccountFooter: View {
    @Environment(AppModel.self) private var model

    private var name: String {
        let account = model.serverAccountBoard.account
        return account?.name.nilIfEmpty ?? account?.email.nilIfEmpty ?? "Crumble"
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(initials)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Palette.bubble, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if model.loading || !model.streamStatus.isEmpty { ConnectionStatus() }
            }
            Spacer(minLength: 0)
            SettingsButton()
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: 30, height: 30)
                .help("Settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var hovered = false

    /// A short description reads as a label beside the name; longer ones stay in the profile.
    private var label: String? {
        guard let description = agent.description?.nilIfEmpty, description.count <= 24 else { return nil }
        return description
    }

    var body: some View {
        HStack(spacing: 10) {
            let state = model.botState(agent)
            // Avatars draw on the CPU every frame, so a bot here animates only while it works or is hovered.
            BotAvatarView(
                agent: agent, size: 44, state: state, live: state == .working || hovered, followsPointer: hovered)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(agent.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !agent.enabled {
                        chip("Paused")
                    } else if let label {
                        chip(label)
                    }
                }
                Text(preview(agent.lastMessage ?? "").nilIfEmpty ?? "No messages yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: .rect(cornerRadius: 5))
    }
}

struct ConnectionStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (status, color): (String, Color) =
            if !model.streamStatus.isEmpty { (model.streamStatus, .red) } else if model.loading {
                ("Syncing…", .secondary)
            } else { ("Connected", .green) }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.loading && model.agents.isEmpty {
            ProgressView("Opening your workspace")
        } else {
            ContentUnavailableView {
                Label("A little help, always here.", systemImage: "sparkles")
            } description: {
                Text("Create an agent with a purpose, then give it something to do.")
            } actions: {
                Button("Create an Agent") { model.createAgent() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.errorText.isEmpty, model.agentDraft == nil, model.memoryDraft == nil, model.automationBoard.draft == nil,
            model.skillDraft == nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(model.errorText).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark") { model.errorText = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.red.opacity(0.15)), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }
}

struct NoticeToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.notice.isEmpty {
            Text(model.notice)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 90)
                .transition(.opacity)
        }
    }
}

/// Shows the model's error inside a sheet, where the window's banner is hidden.
struct SheetError: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.errorText.isEmpty {
            Section {
                Label(model.errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

@MainActor
final class CrumbleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.installDelegate()
    }
    /// Notifications arrive over the app's own server streams, so closing the window keeps it running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// A closed SwiftUI window may no longer exist as an NSWindow, so the scene's own action reopens it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let open = Notifier.shared.openMainWindow else { return true }
        open()
        return false
    }
}

/// Opens the Settings window; the app menu's copy carries ⌘,.
struct SettingsButton: View {
    static let windowID = "settings"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…", systemImage: "gearshape") { openWindow(id: Self.windowID) }
    }
}
