import apfelkern
import BotAvatar
import SwiftUI

/// The column beside a chat, as on the web: the bot's live portrait, its desktop, and its automations.
struct DetailsPanel: View {
    /// The web's `w-72`.
    static let width: CGFloat = 288

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let agent: Agent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                desktopPreview
                automations
            }
            .padding(16)
        }
        .task(id: agent.id) { model.loadAgentDetails(agent.id) }
    }

    private var header: some View {
        VStack(spacing: 8) {
            BotAvatarView(agent: agent, size: 84, state: model.botState(agent), live: true)
            Text(agent.name).font(.title3.weight(.semibold))
            Text(agent.description?.nilIfEmpty ?? (agent.enabled ? "Ready" : "Paused"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder private var desktopPreview: some View {
        if let client = model.client, agent.tools?.contains(DesktopJob.toolName) == true {
            section("Desktop") {
                BotDesktopPreviewCard(preview: BotDesktopPreview(agentID: agent.id, client: client)) {
                    openWindow(id: BotDesktopView.windowID, value: agent.id)
                }
                .id(agent.id)
            }
        }
    }

    private var automations: some View {
        let board = model.automationBoard
        let items = board.schedules(on: agent.id)
        return section("Automations") {
            if !board.isLoaded {
                ProgressView().controlSize(.small)
            } else if items.isEmpty {
                Text("No automations yet").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { automationRow($0) }
        }
    }

    private func automationRow(_ schedule: Schedule) -> some View {
        let board = model.automationBoard
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(schedule.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(automationTiming(schedule, sources: model.connectedServices.eventSources.sources))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = board.errors[schedule.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            Toggle(
                "Run \(schedule.name)",
                isOn: Binding(
                    get: { schedule.enabled },
                    set: { model.setAutomationEnabled(schedule, $0) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(board.isPending(schedule.id))
        }
    }
}
