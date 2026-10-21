import apfelkern
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case memory = "Memory"
    case skills = "Skills"
    case tasks = "Tasks"
    case activity = "Activity"
    case integrations = "Integrations"

    var id: Self { self }

    var route: Route? {
        switch self {
        case .general: nil
        case .memory: .memory
        case .skills: .skills
        case .tasks: .tasks
        case .activity: .activity
        case .integrations: .integrations
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .memory: "brain"
        case .skills: "book.closed"
        case .tasks: "calendar.badge.clock"
        case .activity: "waveform.path.ecg"
        case .integrations: "powerplug"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SettingsPage? = .general

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(SettingsPage.general)
                Section("Workspace") {
                    ForEach(SettingsPage.allCases.filter { $0 != .general }) { page in
                        Label(page.rawValue, systemImage: page.symbol).tag(page)
                    }
                }
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                if let route = selection?.route {
                    PanelView(panel: route)
                        .overlay(alignment: .top) { ErrorBanner() }
                } else {
                    ConnectionSettingsView()
                        .navigationTitle("General")
                }
            }
            .overlay(alignment: .bottom) { NoticeToast() }
        }
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: selection) { _, _ in loadSelection() }
        .onAppear { loadSelection() }
        .onDisappear { model.workspaceRoute = nil }
        .sheet(item: $model.memoryDraft) { MemoryFormView(draft: sheetBinding($model.memoryDraft, for: $0)) }
        .sheet(item: $model.taskDraft) { TaskFormView(draft: sheetBinding($model.taskDraft, for: $0)) }
        .sheet(item: $model.mcpDraft) { MCPFormView(draft: sheetBinding($model.mcpDraft, for: $0)) }
        .sheet(item: $model.skillDraft) { SkillFormView(draft: sheetBinding($model.skillDraft, for: $0)) }
    }

    private func loadSelection() {
        if let route = selection?.route {
            model.openPanel(route)
        } else {
            model.workspaceRoute = nil
        }
    }
}
