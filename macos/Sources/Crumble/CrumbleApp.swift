import AppKit
import SwiftUI

@main
struct CrumbleApp: App {
    @State private var model = AppModel()

    init() {
        // Started from `swift run` there is no bundle telling AppKit this is a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
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
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
                .overlay(alignment: .top) { ErrorBanner() }
                .overlay(alignment: .bottom) { NoticeToast() }
        }
        .sheet(item: $model.agentDraft) { AgentEditorView(draft: sheetBinding($model.agentDraft, for: $0)) }
        .sheet(item: $model.memoryDraft) { MemoryFormView(draft: sheetBinding($model.memoryDraft, for: $0)) }
        .sheet(item: $model.taskDraft) { TaskFormView(draft: sheetBinding($model.taskDraft, for: $0)) }
        .sheet(item: $model.mcpDraft) { MCPFormView(draft: sheetBinding($model.mcpDraft, for: $0)) }
        .sheet(item: $model.skillDraft) { SkillFormView(draft: sheetBinding($model.skillDraft, for: $0)) }
    }

    @ViewBuilder private var detail: some View {
        switch model.route {
        case .agent?, nil:
            if let agent = model.selectedAgent {
                ChatView(agent: agent)
            } else {
                WelcomeView()
            }
        case let panel?:
            PanelView(panel: panel)
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

    private static let workspace: [(Route, String, String)] = [
        (.memory, "Memory", "brain"), (.skills, "Skills", "book.closed"), (.tasks, "Tasks", "calendar.badge.clock"),
        (.activity, "Activity", "waveform.path.ecg"),
        (.approvals, "Approvals", "checkmark.shield"), (.integrations, "Integrations", "powerplug"),
    ]

    var body: some View {
        List(selection: Binding(get: { model.route }, set: { model.navigate(to: $0) })) {
            Section("Agents") {
                ForEach(model.agents) { agent in
                    HStack(spacing: 8) {
                        BotAvatarView(agent: agent, size: 26, state: model.botState(agent))
                        Text(agent.name).lineLimit(1)
                        Spacer()
                        if !agent.enabled {
                            Text("Paused").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Route.agent(agent.id))
                }
                if model.agents.isEmpty {
                    Text("No agents yet").foregroundStyle(.secondary)
                }
            }
            Section("Workspace") {
                ForEach(Self.workspace, id: \.0) { route, title, symbol in
                    Label(title, systemImage: symbol).tag(route)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Agent", systemImage: "square.and.pencil") { model.createAgent() }
            }
        }
        .safeAreaInset(edge: .bottom) { ConnectionStatus() }
    }
}

struct ConnectionStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (status, color): (String, Color) =
            if !model.streamStatus.isEmpty { (model.streamStatus, .red) }
            else if model.loading { ("Syncing…", .secondary) }
            else { ("Connected", .green) }
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
        if !model.errorText.isEmpty, model.agentDraft == nil, model.memoryDraft == nil, model.taskDraft == nil, model.mcpDraft == nil,
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
