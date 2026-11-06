import apfelkern
import Foundation

extension AppModel {
  func loadAutomationsPanel() {
    guard let client else { return }
    automationBoard.refresh(client: client, includingRuns: true)
    connectedServices.eventSources.refresh(client: client)
    loadCapabilities()
  }

  func openNewAutomation() {
    guard let first = agents.first else {
      errorText = "Create an agent before adding an automation."
      return
    }
    automationBoard.openNew(agentID: agents.contains { $0.id == selectedAgentID } ? selectedAgentID : first.id)
  }

  func saveAutomation() {
    guard let client else {
      errorText = "Connect to your server in Settings."
      return
    }
    automationBoard.saveDraft(client: client) { [self] in showNotice("Automation could not be saved") }
  }

  func runAutomation(_ schedule: Schedule) {
    guard let client else { return }
    let routeAtStart = route
    showNotice("Starting automation…")
    automationBoard.run(schedule, client: client) { [self] failure in
      guard failure == nil else {
        showNotice("Automation could not be started")
        return
      }
      showNotice("Automation started")
      if route == routeAtStart, routeAtStart == .automations { selectAgent(schedule.agentId) }
    }
  }

  func setAutomationEnabled(_ schedule: Schedule, _ enabled: Bool) {
    if let client { automationBoard.setEnabled(schedule, enabled, client: client) }
  }
}
