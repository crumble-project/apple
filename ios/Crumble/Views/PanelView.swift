import apfelkern
import AuthenticationServices
import SwiftUI

/// The workspace pages: memory, skills, tasks, activity, integrations, coding, users, and
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
            Button("New Memory", systemImage: "plus") {
              model.openMemoryForm("", agentID: nil)
            }
          case .skills:
            Menu("Skill Sources", systemImage: "square.and.arrow.down") {
              Button("Install from GitHub", systemImage: "square.and.arrow.down") {
                model.openSkillInstall()
              }
              if model.skillCatalog.installed {
                Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                  model.checkSkillUpdates()
                }
                .disabled(model.sharedSkillBoard.checking)
              }
            }
            Button("New Shared Skill", systemImage: "plus") { model.openSkillForm("") }
          case .tasks:
            Button("New Task", systemImage: "plus") { model.openTaskForm("") }.disabled(
              model.agents.isEmpty)
          case .integrations:
            Button("Add Shared MCP Server", systemImage: "plus") {
              model.openMCPForm("", agentID: nil)
            }
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
    case .tasks: TasksPanel()
    case .activity: ActivityPanel()
    case .integrations: IntegrationsPanel()
    case .coding: CodingPanel()
    case .users: UsersPanel()
    case .passwordManagers: PasswordManagersPanel()
    case .webSearch: WebSearchPanel()
    case .judgeModel: ModelSettingPanel(board: model.connectedServices.judgeModel)
    case .visionModel: ModelSettingPanel(board: model.connectedServices.visionModel)
    case .messageGateways: MessageGatewaysPanel()
    case .eventRelay: EventRelayPanel()
    case .agent, .group: EmptyView()
    }
  }
}
