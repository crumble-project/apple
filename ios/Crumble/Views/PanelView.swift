import apfelkern
import AuthenticationServices
import SwiftUI

/// The workspace pages: memory, skills, tasks, activity, and integrations.
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
    case .agent: EmptyView()
    }
  }
}
