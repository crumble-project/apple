import apfelkern
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case memory = "Memory"
    case skills = "Skills"
    case tasks = "Tasks"
    case activity = "Activity"
    case judgeModel = "Judge model"
    case visionModel = "Vision model"
    case integrations = "Integrations"
    case coding = "Coding"
    case users = "Users"
    case passwordManagers = "Password managers"
    case webSearch = "Web search"
    case messageGateways = "Message gateways"
    case eventRelay = "Event relay"

    var id: Self { self }

    var route: Route? {
        switch self {
        case .general: nil
        case .memory: .memory
        case .skills: .skills
        case .tasks: .tasks
        case .activity: .activity
        case .judgeModel: .judgeModel
        case .visionModel: .visionModel
        case .integrations: .integrations
        case .coding: .coding
        case .users: .users
        case .passwordManagers: .passwordManagers
        case .webSearch: .webSearch
        case .messageGateways: .messageGateways
        case .eventRelay: .eventRelay
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .memory: "brain"
        case .skills: "book.closed"
        case .tasks: "calendar.badge.clock"
        case .activity: "waveform.path.ecg"
        case .judgeModel: JudgeModelSettings.symbol
        case .visionModel: VisionModelSettings.symbol
        case .integrations: "powerplug"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .users: "person.2"
        case .passwordManagers: "lock.rectangle.stack"
        case .webSearch: "globe"
        case .messageGateways: "message"
        case .eventRelay: "dot.radiowaves.left.and.right"
        }
    }

    static let connectedServices: [SettingsPage] = [.passwordManagers, .webSearch, .messageGateways, .eventRelay]
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
                Section("Connected services") {
                    ForEach(SettingsPage.connectedServices) { page in
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
        .machineAccountSheet()
        .adminSheets()
        .messageGatewaySheet()
        .pluginSettingSheet(active: model.connectedServices.gateways.draft == nil)
        .gitHubAppSheets()
        .skillSheet(active: model.agentDraft == nil)
    }

    private var pages: [SettingsPage] {
        SettingsPage.allCases.filter {
            $0 != .general && !SettingsPage.connectedServices.contains($0) && ($0 != .users || model.adminBoard.isAdmin)
        }
    }

    private func loadSelection() {
        if let route = selection?.route {
            model.openPanel(route)
        } else {
            model.workspaceRoute = nil
        }
    }
}
