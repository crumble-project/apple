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
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    Notifier.shared.start(model: model)
                    model.refresh()
                    model.followActivity()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Agent") { model.createAgent() }.keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView().environment(model)
        }
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 680)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
                .overlay(alignment: .top) { ErrorBanner() }
                .overlay(alignment: .bottom) { NoticeToast() }
        }
        .onAppear {
            PushNotifications.shared.openMainWindow = { openWindow(id: "main") }
        }
        .sheet(item: $model.agentDraft) { AgentEditorView(draft: sheetBinding($model.agentDraft, for: $0)) }
    }

    @ViewBuilder private var detail: some View {
        if let agent = model.selectedAgent {
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
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""

    private var filteredAgents: [Agent] {
        guard !search.isEmpty else { return model.agents }
        return model.agents.filter {
            $0.name.localizedStandardContains(search) || ($0.lastMessage ?? "").localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .padding(12)

            List(selection: Binding(get: { model.route }, set: { model.navigate(to: $0) })) {
                ForEach(filteredAgents) { agent in
                    agentRow(agent)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filteredAgents.isEmpty {
                    Text(model.agents.isEmpty ? "No agents yet" : "No results")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.blue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Agent", systemImage: "square.and.pencil") { model.createAgent() }
                    .help("New Agent (⌘N)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if model.loading || !model.streamStatus.isEmpty { ConnectionStatus() }
                Spacer(minLength: 0)
                Button("Settings", systemImage: "gearshape") { openSettings() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 40, height: 40)
                    .help("Settings (⌘,)")
            }
            .padding(.horizontal, 8)
        }
    }

    private func agentRow(_ agent: Agent) -> some View {
        HStack(spacing: 12) {
            BotAvatarView(agent: agent, size: 44, state: model.botState(agent), live: model.route == .agent(agent.id))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if !agent.enabled {
                        Text("Paused").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(preview(agent.lastMessage ?? "").nilIfEmpty ?? "No messages yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .tag(Route.agent(agent.id))
        .disabled(model.pendingMutations.contains("agent:\(agent.id)"))
    }
}

struct ConnectionStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (status, color): (String, Color) =
            if !model.streamStatus.isEmpty { (model.streamStatus, .red) } else if model.loading {
                ("Syncing…", .secondary)
            } else { ("Connected", .green) }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
        if !model.errorText.isEmpty, model.agentDraft == nil, model.memoryDraft == nil, model.taskDraft == nil,
            model.mcpDraft == nil,
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
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.receivedToken(deviceToken)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.registrationFailed()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await PushNotifications.shared.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.title == "Crumble" }?.makeKeyAndOrderFront(nil) }
        return true
    }
}
