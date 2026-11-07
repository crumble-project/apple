import apfelkern
import BotAvatar
import SwiftUI

struct AutomationsPanel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    AutomationsPage(
      board: model.automationBoard, agents: model.agents,
      sources: model.connectedServices.eventSources.sources, client: model.client,
      onCreate: model.openNewAutomation, onRun: model.runAutomation, onOpenBot: { model.selectAgent($0) })
  }
}
