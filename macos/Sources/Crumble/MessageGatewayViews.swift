import apfelkern
import SwiftUI

struct MessageGatewaysPanel: View {
    @Environment(AppModel.self) private var model

    private var board: MessageGatewayBoard { model.connectedServices.gateways }

    var body: some View {
        Form {
            Section {
                if let error = board.readError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if !board.isLoaded, board.readError == nil { ProgressView() }
                if board.isLoaded, board.gateways.isEmpty {
                    Text("This server has no message gateways.").foregroundStyle(.secondary)
                }
                ForEach(board.gateways) { GatewayRow(gateway: $0) }
            } header: {
                Text("Gateways")
            } footer: {
                Text("Message your bots from other chat apps.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: board.watchKey) { await model.watchMessageGateways() }
    }
}

private struct GatewayRow: View {
    @Environment(AppModel.self) private var model
    let gateway: MessageGateway

    private var board: MessageGatewayBoard { model.connectedServices.gateways }

    var body: some View {
        HStack {
            Text(gateway.label).fontWeight(.semibold)
            GatewayStatusText(gateway: gateway)
            Spacer()
            if board.isUnconfirmed(gateway) { ProgressView().controlSize(.small) }
            Button("Edit") { board.edit(gateway) }
                .accessibilityLabel("Edit \(gateway.label)")
                .disabled(board.isUnconfirmed(gateway))
        }
    }
}

private struct GatewayStatusText: View {
    let gateway: MessageGateway

    var body: some View {
        Text(gateway.statusLabel)
            .font(.caption)
            .foregroundStyle(gateway.isFailing ? .red : .secondary)
    }
}

/// Saving shows at once and reopens this with the error on failure. The token saves on its own, as
/// on the web, so the Connection section doesn't wait for the rest of the form.
private struct GatewaySheet: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: GatewayDraft

    private var board: MessageGatewayBoard { model.connectedServices.gateways }
    private var gateway: MessageGateway? { board.gateway(draft.gatewayID) }

    private var errors: GatewayDraftErrors { draft.shownErrors(bots: model.agents) }

    var body: some View {
        NavigationStack {
            Form {
                ServiceSaveStatus(isSaving: false, error: board.saveError)
                connection
                bots
                access
            }
            .formStyle(.grouped)
            .navigationTitle(draft.label)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { board.closeDraft() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveGatewayDraft() }.disabled(!board.canSave)
                }
            }
        }
        .frame(width: 520, height: 620)
        .pluginSettingSheet()
    }

    @ViewBuilder private var connection: some View {
        Section("Connection") {
            Toggle(isOn: $draft.enabled) {
                HStack {
                    Text(draft.label)
                    if let gateway { GatewayStatusText(gateway: gateway) }
                }
            }
            if let deliveries = gateway?.deliveries.nilIfEmpty {
                Text(deliveries).font(.caption).foregroundStyle(.secondary)
            }
            if let error = gateway?.error {
                ServiceAlert(title: "Connection needs attention", message: error)
            }
            if let gateway {
                PluginSettingRows(selection: .secretKey(gateway.secretKey))
            }
        }
    }

    private var bots: some View {
        Section {
            Picker("Default bot", selection: $draft.defaultBotID) {
                Text("None").tag(String?.none)
                ForEach(MessageGateway.botChoices(model.agents, keeping: draft.defaultBotID)) {
                    Text($0.name).tag(Optional($0.id))
                }
            }
            fieldError(errors.defaultBot)
            ForEach($draft.aliases) { $alias in
                HStack {
                    TextField("Alias", text: $alias.handle, prompt: Text("research"))
                        .accessibilityLabel("Alias")
                        .labelsHidden()
                        .autocorrectionDisabled()
                    Picker("Bot for alias", selection: $alias.botID) {
                        Text("Choose a bot").tag("")
                        ForEach(MessageGateway.botChoices(model.agents, keeping: alias.botID)) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    .labelsHidden()
                    Button("Remove Alias", systemImage: "trash") { draft.aliases.removeAll { $0.id == alias.id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            fieldError(errors.aliases)
            Button("Add Alias", systemImage: "plus") { draft.aliases.append(GatewayDraft.AliasRow()) }
                .disabled(model.agents.isEmpty)
        } header: {
            Text("Bots")
        } footer: {
            Text("Start a message with @alias to pick a bot.").foregroundStyle(.secondary)
        }
    }

    private var access: some View {
        Section("Access") {
            TextField(draft.ownerLabel, text: $draft.ownerID)
                .accessibilityLabel(draft.ownerLabel)
                .autocorrectionDisabled()
                .fontDesign(.monospaced)
            fieldError(errors.owner)
            Toggle("Direct messages", isOn: $draft.allowDirectMessages)
            ForEach($draft.channels) { $channel in
                HStack {
                    TextField("Channel ID", text: $channel.value, prompt: Text("Channel ID"))
                        .accessibilityLabel("Channel ID")
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                    Button("Remove Channel", systemImage: "trash") { draft.channels.removeAll { $0.id == channel.id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            fieldError(errors.channels)
            Button("Add Channel", systemImage: "plus") { draft.channels.append(GatewayDraft.ChannelRow()) }
        }
    }

    @ViewBuilder private func fieldError(_ message: String?) -> some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

private struct MessageGatewaySheetModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    private var board: MessageGatewayBoard { model.connectedServices.gateways }

    private var draft: Binding<GatewayDraft?> {
        Binding(
            get: { board.draft },
            set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
    }

    func body(content: Content) -> some View {
        content.sheet(item: draft) { GatewaySheet(draft: sheetBinding(draft, for: $0)) }
    }
}

extension View {
    func messageGatewaySheet() -> some View {
        modifier(MessageGatewaySheetModifier())
    }
}
