import apfelkern
import SwiftUI

extension BotSecretKind {
    fileprivate var icon: String { self == .credential ? "key" : "person.badge.key" }
}

/// A bot's credentials or logins in the bot editor, with what it waits for at the top.
struct BotSecretsSection: View {
    @Environment(AppModel.self) private var model
    let kind: BotSecretKind
    let agentID: String

    private var board: BotSecretBoard { model.botSecretBoard }

    var body: some View {
        let items = board.items(kind, agentID: agentID)
        let requests = board.requests(kind, agentID: agentID)
        Section {
            ForEach(requests) { BotSecretRequestRow(request: $0, kind: kind, agentID: agentID) }
            ForEach(items) { BotSecretRow(item: $0, agentID: agentID) }
            if let error = board.readError(kind, agentID: agentID) {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else if items.isEmpty, requests.isEmpty, board.isLoaded(kind, agentID: agentID) {
                Text(kind.emptyText).foregroundStyle(.secondary)
            }
            Button("New \(kind.noun)…") { model.newBotSecret(kind, agentID: agentID) }
        } header: {
            Text(kind.title)
        } footer: {
            Text(kind.note).foregroundStyle(.secondary)
        }
    }
}

private struct BotSecretRequestRow: View {
    @Environment(AppModel.self) private var model
    let request: BotSecretRequest
    let kind: BotSecretKind
    let agentID: String

    private var target: BotSecretTarget { BotSecretTarget(kind: kind, agentID: agentID, name: request.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Asks for ").foregroundStyle(.secondary)
                    + Text(request.name).fontDesign(kind == .credential ? .monospaced : .default).fontWeight(.medium)
            } icon: {
                Image(systemName: "bell")
            }
            Text(([request.reason] + request.hosts).joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let error = model.botSecretBoard.errors[target] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if model.botSecretBoard.declining.contains(target) { ProgressView().controlSize(.small) }
                Button("Decline") { model.declineBotSecret(request, kind: kind, agentID: agentID) }
                    .buttonStyle(.borderless)
                    .disabled(model.botSecretBoard.declining.contains(target))
                Button("Add") { model.addBotSecret(request, kind: kind, agentID: agentID) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct BotSecretRow: View {
    @Environment(AppModel.self) private var model
    let item: BotSecret
    let agentID: String
    @State private var confirmingDelete = false

    private var target: BotSecretTarget { BotSecretTarget(kind: item.kind, agentID: agentID, name: item.name) }
    private var unconfirmed: Bool { model.botSecretBoard.isUnconfirmed(target) }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.editBotSecret(item, agentID: agentID) } label: { details }
                .buttonStyle(.plain)
                .disabled(item.managed || unconfirmed)
            Spacer(minLength: 0)
            Menu {
                Button(item.kind.usesLabel, systemImage: "clock") { model.showBotSecretUses(item, agentID: agentID) }
                if !item.managed {
                    Button("Edit", systemImage: "pencil") { model.editBotSecret(item, agentID: agentID) }
                    Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(item.name)")
            .disabled(unconfirmed)
        }
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteBotSecret(item, agentID: agentID) }
        } message: {
            Text(item.kind.deleteWarning)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .fontDesign(item.kind == .credential ? .monospaced : .default)
                .fontWeight(.medium)
            Text(item.hosts.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(item.lastUse())
                .font(.system(size: 12))
                .foregroundStyle(item.lastError == nil ? Color.secondary : Color.red)
            if let error = model.botSecretBoard.errors[target] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// A bot's request for a credential or login in its chat. It stays until the server says it ended.
struct BotSecretRequestCard: View {
    @Environment(AppModel.self) private var model
    let ask: BotSecretAsk

    var body: some View {
        switch model.botSecretBoard.state(of: ask) {
        case .waiting(let request): BotSecretRequestPendingView(ask: ask, request: request)
        case .outcome(let outcome): settled(outcome)
        }
    }

    private func settled(_ outcome: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ask.kind.icon).foregroundStyle(.secondary)
            Text(ask.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Text(outcome).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.bubble, in: .rect(cornerRadius: 14))
    }
}

private struct BotSecretRequestPendingView: View {
    @Environment(AppModel.self) private var model
    let ask: BotSecretAsk
    let request: BotSecretRequest
    @State private var expanded = false

    private var agentID: String { model.selectedAgentID }
    private var target: BotSecretTarget { BotSecretTarget(kind: ask.kind, agentID: agentID, name: request.name) }
    private var declining: Bool { model.botSecretBoard.declining.contains(target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ask.kind.icon).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    hosts
                }
            }
            if let error = model.botSecretBoard.errors[target] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if declining { ProgressView().controlSize(.small) }
                Button("Decline") { model.declineBotSecret(request, kind: ask.kind, agentID: agentID) }
                    .disabled(declining)
                Button("Add \(ask.kind.noun)") { model.addBotSecret(request, kind: ask.kind, agentID: agentID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(declining)
            }
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.bubble, in: .rect(cornerRadius: 14))
    }

    private var hosts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            let more = request.hosts.count - 1
            Text((expanded ? request.hosts : Array(request.hosts.prefix(1))).joined(separator: " "))
            if more > 0 {
                Button(expanded ? "Show less" : "\(more) more") { expanded.toggle() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}
