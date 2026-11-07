import apfelkern
import AuthenticationServices
import SwiftUI

/// The workspace pages: memory, skills, automations, activity, integrations, coding, users, and
/// connected services.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    let panel: Route

    var body: some View {
        content
            .navigationTitle(panel.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    switch panel {
                    case .memory:
                        Button("New Memory", systemImage: "plus") { model.openMemoryForm("", agentID: nil) }
                    case .skills:
                        if model.skillCatalog.installed {
                            Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                                model.checkSkillUpdates()
                            }
                            .disabled(model.sharedSkillBoard.checking)
                        }
                        Button("Install from GitHub", systemImage: "square.and.arrow.down") {
                            model.openSkillInstall()
                        }
                        Button("New Skill", systemImage: "plus") { model.openSkillForm("") }
                    case .automations:
                        Button("New Automation", systemImage: "plus") { model.openNewAutomation() }.disabled(
                            model.agents.isEmpty)
                    case .integrations:
                        Button("Add MCP Server", systemImage: "plus") { model.openMCPForm("", agentID: nil) }
                    default:
                        EmptyView()
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { model.openPanel(panel) }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .memory: MemoryPanel()
        case .skills: SkillsPanel()
        case .automations: AutomationsPanel()
        case .activity: ActivityPanel()
        case .avatars: AvatarsPanel()
        case .integrations: IntegrationsPanel()
        case .coding: CodingPanel()
        case .users: UsersPanel()
        case .providers: ProvidersPanel()
        case .passwordManagers: PasswordManagersPanel()
        case .credentials: BotSecretPanel(kind: .credential)
        case .logins: BotSecretPanel(kind: .login)
        case .webSearch: WebSearchPanel()
        case .judgeModel: ModelSettingPanel(board: model.connectedServices.judgeModel)
        case .visionModel: ModelSettingPanel(board: model.connectedServices.visionModel)
        case .messageGateways: MessageGatewaysPanel()
        case .eventRelay: EventRelayPanel()
        case .agent, .group: EmptyView()
        }
    }
}
