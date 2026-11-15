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
    /// Avatars draw on the CPU every frame, so the portrait comes alive only under the pointer.
    @State private var avatarHovered = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                settingsRow
                desktopPreview
                automations
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .task(id: agent.id) { model.loadAgentDetails(agent.id) }
    }

    private var header: some View {
        VStack(spacing: 6) {
            CalmAvatar(agent: agent, size: 72, state: model.botState(agent), active: avatarHovered)
                .onHover { avatarHovered = $0 }
                .padding(.bottom, 4)
            Text(agent.name).font(.system(size: 17, weight: .semibold))
            Text(agent.description?.nilIfEmpty ?? (agent.enabled ? "Ready" : "Paused"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
    }

    private var settingsRow: some View {
        Button {
            model.openEditor(agentID: agent.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 16)
                Text("Bot settings").font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .card()
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
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
            VStack(alignment: .leading, spacing: 0) {
                if !board.isLoaded {
                    ProgressView().controlSize(.small).padding(12)
                } else if items.isEmpty {
                    Text("No automations yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, schedule in
                    if index > 0 { Divider().padding(.leading, 12) }
                    automationRow(schedule).padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func automationRow(_ schedule: Schedule) -> some View {
        let board = model.automationBoard
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(schedule.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(schedule.timing)
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
