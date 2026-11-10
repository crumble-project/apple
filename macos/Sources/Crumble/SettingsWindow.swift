import apfelkern
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case memory = "Memory"
    case skills = "Skills"
    case automations = "Automations"
    case activity = "Activity"
    case avatars = "Avatars"

    var id: Self { self }

    var route: Route? {
        switch self {
        case .general: nil
        case .memory: .memory
        case .skills: .skills
        case .automations: .automations
        case .activity: .activity
        case .avatars: .avatars
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .memory: "brain"
        case .skills: "book.closed"
        case .automations: "calendar.badge.clock"
        case .activity: "waveform.path.ecg"
        case .avatars: "face.smiling"
        }
    }
}

/// Where the command palette sends the Settings window.
enum SettingsTarget: Equatable {
    case general
    case page(Route)
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
                    ForEach(pages) { page in
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
        .modifier(FollowsTheme(board: model.themeBoard))
        .onChange(of: selection) { _, _ in loadSelection() }
        .onChange(of: model.settingsTarget, initial: true) { _, target in
            switch target {
            case .general: selection = .general
            case .page(let route): selection = SettingsPage.allCases.first { $0.route == route }
            case nil: return
            }
            model.settingsTarget = nil
        }
        .onAppear { loadSelection() }
        .onDisappear { model.workspaceRoute = nil }
        .sheet(item: $model.memoryDraft) { MemoryFormView(draft: sheetBinding($model.memoryDraft, for: $0)) }
        .automationSheet(active: model.settingsShowsAutomations)
        .skillSheet(active: model.agentDraft == nil)
    }

    private var pages: [SettingsPage] {
        SettingsPage.allCases.filter { $0 != .general }
    }

    private func loadSelection() {
        if let route = selection?.route {
            model.openPanel(route)
        } else {
            model.workspaceRoute = nil
        }
    }
}
