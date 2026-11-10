import apfelkern
import SwiftUI

/// The workspace pages: memory, skills, automations, activity, and avatars.
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
        case .agent, .group: EmptyView()
        }
    }
}
