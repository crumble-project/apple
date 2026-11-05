import apfelkern
import BotAvatar
import SwiftUI

/// A bot's proposal for a new bot: the owner approves, edits, or declines it here.
struct BotRequestCard: View {
    @Environment(AppModel.self) private var model
    let request: BotRequest

    var body: some View {
        let live = model.botRequestBoard.current(request)
        if live.status == .pending {
            BotRequestPendingView(request: live)
        } else {
            settled(live)
        }
    }

    private func settled(_ request: BotRequest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2").foregroundStyle(.secondary)
            Text(request.proposal.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Text(request.status == .approved ? "Approved" : "Declined")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let id = request.createdAgentID, model.agents.contains(where: { $0.id == id }) {
                Button("Open Chat") { model.selectAgent(id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.bubble, in: .rect(cornerRadius: 14))
    }
}

private struct BotRequestPendingView: View {
    @Environment(AppModel.self) private var model
    let request: BotRequest

    private var decision: BotRequestDecision { model.botRequestBoard.decision(for: request.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let description = request.proposal.description?.nilIfEmpty {
                Text(description).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            let capabilities = request.capabilityNames(servers: model.mcpServers)
            if !capabilities.isEmpty {
                Text(capabilities.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !decision.error.isEmpty {
                Text(decision.error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            buttons
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.bubble, in: .rect(cornerRadius: 14))
        .task(id: request.id) { await model.loadBotRequestServers(request) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BotAvatarView(avatar: request.proposal.avatar, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.proposal.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text("\(request.proposal.provider ?? "") · \(request.proposal.model ?? "")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Edit", systemImage: "pencil") { model.openEditor(botRequest: request) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(decision.sending)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if decision.sending { ProgressView().controlSize(.small) }
            Button("Decline") { model.declineBotRequest(request) }
            Button("Approve") { model.approveBotRequest(request) }
                .buttonStyle(.borderedProminent)
        }
        .disabled(decision.sending)
    }
}

/// Above the bot editor when it holds a proposal: approving is still up to the server.
struct BotRequestEditorStatus: View {
    @Environment(AppModel.self) private var model
    let request: BotRequest

    private var decision: BotRequestDecision { model.botRequestBoard.decision(for: request.id) }

    var body: some View {
        Section {
            Text("Review the proposed bot before approving it.").foregroundStyle(.secondary)
            if decision.sending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Approving…")
                }
            }
            if !decision.error.isEmpty {
                Label(decision.error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}
