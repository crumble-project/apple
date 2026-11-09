import apfelkern
import BotAvatar
import SwiftUI

/// The inspector beside a chat, laid out as on Android: the bot's live portrait, its desktop, and its automations.
struct DetailsPanel: View {
  @Environment(AppModel.self) private var model
  @Environment(\.horizontalSizeClass) private var sizeClass
  let agent: Agent
  /// Opens a page that covers the panel, which a phone must close first.
  let leave: (@escaping () -> Void) -> Void
  let close: () -> Void

  var body: some View {
    Form {
      header
      desktopPreview
      automations
    }
    .formStyle(.grouped)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if sizeClass == .compact {
        ToolbarItem(placement: .cancellationAction) { Button(role: .close, action: close) }
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Edit Bot", systemImage: "pencil") { leave { model.openEditor(agentID: agent.id) } }
      }
    }
    .task(id: agent.id) { model.loadAgentDetails(agent.id) }
  }

  private var header: some View {
    VStack(spacing: 8) {
      BotAvatarView(agent: agent, size: 84, state: model.botState(agent), live: true)
      Text(agent.name).font(.title2.weight(.semibold))
      Text(agent.description?.nilIfEmpty ?? (agent.enabled ? "Ready" : "Paused"))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .listRowBackground(Color.clear)
  }

  @ViewBuilder private var desktopPreview: some View {
    if let client = model.client, agent.tools?.contains(DesktopJob.toolName) == true {
      Section("Desktop") {
        BotDesktopPreviewCard(preview: BotDesktopPreview(agentID: agent.id, client: client)) {
          leave { model.botDesktop = BotDesktopTarget(id: agent.id) }
        }
        .id(agent.id)
        .listRowInsets(EdgeInsets())
      }
    }
  }

  private var automations: some View {
    let board = model.automationBoard
    let items = board.schedules(on: agent.id)
    return Section("Automations") {
      if items.isEmpty {
        Text("No automations yet").foregroundStyle(.secondary)
      }
      ForEach(items) { schedule in
        Toggle(
          isOn: Binding(
            get: { schedule.enabled },
            set: { model.setAutomationEnabled(schedule, $0) })
        ) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(schedule.name).lineLimit(1)
              Text(automationTiming(schedule, sources: model.connectedServices.eventSources.sources))
                .font(.subheadline)
                .foregroundStyle(.secondary)
              if let error = board.errors[schedule.id] { Text(error).font(.subheadline).foregroundStyle(.red) }
            }
          } icon: {
            SettingsIcon(symbol: "calendar.badge.clock", color: .red)
          }
        }
        .disabled(board.isPending(schedule.id))
      }
    }
  }
}
