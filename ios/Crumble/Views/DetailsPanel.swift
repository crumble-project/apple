import apfelkern
import BotAvatar
import SwiftUI

/// The inspector beside a chat: the bot's live portrait, its desktop, its automations, and what it remembers.
struct DetailsPanel: View {
  @Environment(AppModel.self) private var model
  let agent: Agent
  /// Opens a page that covers the panel, which a phone must close first.
  let leave: (@escaping () -> Void) -> Void
  @State private var tab = Tab.details

  enum Tab { case details, memory }

  var body: some View {
    Form {
      header
      Section {
        Picker("View", selection: $tab) {
          Text("Details").tag(Tab.details)
          Text("Memory").tag(Tab.memory)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      switch tab {
      case .details:
        desktopPreview
        automations
        modelSection
      case .memory:
        memories
      }
    }
    .formStyle(.grouped)
    .task(id: agent.id) { model.loadAgentDetails(agent.id) }
  }

  private var header: some View {
    VStack(spacing: 2) {
      BotAvatarView(agent: agent, size: 84, state: model.botState(agent), live: true)
      Text(agent.name).font(.title3.weight(.semibold)).padding(.top, 4)
      Text(agent.description?.nilIfEmpty ?? (agent.enabled ? "Ready" : "Paused"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
      Button("Edit Profile…") { leave { model.openEditor(agentID: agent.id) } }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.top, 4)
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
          Text(schedule.name)
          Text(automationTiming(schedule, sources: model.connectedServices.eventSources.sources))
          if let error = board.errors[schedule.id] { Text(error).foregroundStyle(.red) }
        }
        .disabled(board.isPending(schedule.id))
      }
    }
  }

  private var modelSection: some View {
    Section("Model") {
      LabeledContent("Model", value: agent.model?.nilIfEmpty ?? "Default")
      if let provider = agent.provider?.nilIfEmpty {
        LabeledContent("Provider", value: provider)
      }
    }
  }

  private var memories: some View {
    Section("Memories") {
      if let items = model.agentMemories[agent.id] {
        if items.isEmpty {
          Text("Nothing remembered yet").foregroundStyle(.secondary)
        }
        ForEach(items) { memory in
          VStack(alignment: .leading, spacing: 2) {
            Text(memory.content).lineLimit(4).textSelection(.enabled)
            if let source = memorySourceLabel(memory.source) {
              Text(source).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
      }
    }
  }
}
