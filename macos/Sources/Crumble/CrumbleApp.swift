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
    /// The main window is key or main in the active app; another window, a minimized one, or another app isn't.
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .onChange(of: appearsActive, initial: true) { _, active in model.attentionActive = active }
        .onDisappear { model.attentionActive = false }
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

    /// Switching chats crossfades instead of cutting, so the change reads as one motion.
    private var detail: some View {
        ZStack {
            if let group = model.selectedGroup {
                GroupChatView(group: group).id("group:" + group.id).transition(.opacity)
            } else if let agent = model.selectedAgent {
                ChatView(agent: agent).id("agent:" + agent.id).transition(.opacity)
            } else {
                WelcomeView()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.route)
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
