import apfelkern
import BotAvatar
import SwiftUI

struct PasswordManagersPanel: View {
    var body: some View {
        Form { PasswordManagersSection() }.formStyle(.grouped)
    }
}

/// Opens from a secret's sheet, so connecting one keeps what the owner typed there.
struct PasswordManagersSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { PasswordManagersSection() }
                .formStyle(.grouped)
                .navigationTitle("Password managers")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(width: 460, height: 320)
    }
}

private struct PasswordManagersSection: View {
    @Environment(AppModel.self) private var model

    private var board: PasswordManagerBoard { model.connectedServices.passwordManagers }

    var body: some View {
        Section {
            if let error = board.readError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if !board.isLoaded, board.readError == nil { ProgressView() }
            ForEach(board.managers) { PasswordManagerRow(manager: $0) }
        } footer: {
            Text("Credentials, provider API keys, and MCP server tokens can be read from a connected password "
                + "manager instead of being stored in Crumble.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PasswordManagerRow: View {
    @Environment(AppModel.self) private var model
    let manager: PasswordManager
    @State private var confirmingDisconnect = false

    private var board: PasswordManagerBoard { model.connectedServices.passwordManagers }
    private var inUse: Bool { !manager.usedBy.isEmpty }

    private var draft: Binding<PasswordManagerDraft?> {
        Binding(
            get: { board.draft?.manager.id == manager.id ? board.draft : nil },
            set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
    }

    var body: some View {
        HStack {
            BrandLogoView(.passwordManager(manager.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.name).fontWeight(.semibold)
                if inUse {
                    Text("Used by \(manager.usedBy.count)").font(.caption).foregroundStyle(.secondary)
                }
                if let error = board.errors[manager.id] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            if board.isUnconfirmed(manager) { ProgressView().controlSize(.small) }
            if manager.connected {
                Button("Replace Token") { board.open(manager) }
                Button(inUse ? "Disconnect (in use)" : "Disconnect") { confirmingDisconnect = true }
                    .disabled(inUse)
            } else {
                Button("Connect") { board.open(manager) }
                    .accessibilityLabel("Connect \(manager.name)")
            }
        }
        .disabled(board.isUnconfirmed(manager))
        .confirmationDialog(
            "Disconnect \(manager.name)?", isPresented: $confirmingDisconnect, titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { model.disconnectPasswordManager(manager) }
        } message: {
            Text("Crumble drops its token. You'll need the token to connect it again.")
        }
        .sheet(item: draft) { PasswordManagerTokenSheet(draft: sheetBinding(draft, for: $0)) }
    }
}

/// A token depends on the password manager, so this waits for the server and can't close until then.
private struct PasswordManagerTokenSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: PasswordManagerDraft

    private var board: PasswordManagerBoard { model.connectedServices.passwordManagers }

    var body: some View {
        NavigationStack {
            Form {
                ServiceSaveStatus(isSaving: board.isSaving, label: "Checking…", error: board.saveError)
                Section {
                    SecureField(draft.manager.id.tokenLabel, text: $draft.token)
                        .privacySensitive()
                    if draft.manager.connected {
                        Text("Values read with the old token are dropped.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(draft.note).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(board.isSaving)
            .navigationTitle(draft.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { board.closeDraft() }.disabled(board.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.saveLabel) { model.savePasswordManagerDraft() }.disabled(!board.canSave)
                }
            }
        }
        .frame(width: 460, height: 280)
        .interactiveDismissDisabled(board.isSaving)
    }
}

/// A save's pending state or the reason it failed, at the top of a sheet's form.
struct ServiceSaveStatus: View {
    let isSaving: Bool
    var label = "Saving…"
    let error: String

    var body: some View {
        if isSaving {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label)
                }
            }
        } else if !error.isEmpty {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A connection's error, as the web shows it above the settings that can fix it.
struct ServiceAlert: View {
    let title: String
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message).textSelection(.enabled)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
    }
}

/// The rows for the plugin settings a page shows. Their sheet comes from `pluginSettingSheet`.
struct PluginSettingRows: View {
    @Environment(AppModel.self) private var model
    let selection: PluginSettingSelection

    private var board: PluginSettingBoard { model.connectedServices.pluginSettings }

    var body: some View {
        if let error = board.readError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        ForEach(board.settings(selection)) { PluginSettingRow(setting: $0) }
    }
}

private struct PluginSettingRow: View {
    @Environment(AppModel.self) private var model
    let setting: PluginSetting
    @State private var confirmingRemove = false

    private var board: PluginSettingBoard { model.connectedServices.pluginSettings }

    private var manager: String? {
        model.connectedServices.passwordManagers.managers.first { $0.id == setting.secret.passwordManager }?.name
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.label).fontWeight(.semibold)
                if let manager { Text(manager).font(.caption).foregroundStyle(.secondary) }
                if let error = board.errors[setting.id] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            if board.isUnconfirmed(setting) { ProgressView().controlSize(.small) }
            if setting.secret.configured {
                Button("Edit") { board.edit(setting) }
                    .accessibilityLabel("Edit \(setting.label)")
                Button("Remove") { confirmingRemove = true }
                    .accessibilityLabel("Remove \(setting.label)")
            } else {
                Button("Add") { board.edit(setting) }
                    .accessibilityLabel("Add \(setting.label)")
            }
        }
        .disabled(board.isUnconfirmed(setting))
        .confirmationDialog("Remove \(setting.label)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.removePluginSetting(setting) }
        } message: {
            Text("Crumble forgets it. Whatever needs it stops working until you add it again.")
        }
    }
}

/// Saving a value shows at once and reopens this with the error on failure. A password manager
/// check holds it until the server answers. A typed value lives on the board until this closes.
private struct PluginSettingSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: PluginSettingDraft

    private var board: PluginSettingBoard { model.connectedServices.pluginSettings }

    var body: some View {
        NavigationStack {
            Form {
                ServiceSaveStatus(isSaving: board.isSaving, error: board.saveError)
                Section {
                    SecretSourceField(label: "Value", source: $draft.source)
                }
            }
            .formStyle(.grouped)
            .disabled(board.isSaving)
            .navigationTitle(draft.setting.label)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { board.closeDraft() }.disabled(board.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.savePluginSettingDraft() }.disabled(!board.canSave)
                }
            }
        }
        .frame(width: 460, height: 300)
        .interactiveDismissDisabled(board.isSaving)
    }
}

private struct PluginSettingSheetModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    private var board: PluginSettingBoard { model.connectedServices.pluginSettings }

    private var draft: Binding<PluginSettingDraft?> {
        Binding(
            get: { active ? board.draft : nil },
            set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
    }

    func body(content: Content) -> some View {
        content.sheet(item: draft) { PluginSettingSheet(draft: sheetBinding(draft, for: $0)) }
    }
}

extension View {
    /// Pass `active: false` where another sheet is up and presents this one itself.
    func pluginSettingSheet(active: Bool = true) -> some View {
        modifier(PluginSettingSheetModifier(active: active))
    }
}

struct EventRelayPanel: View {
    @Environment(AppModel.self) private var model

    private var board: EventRelayBoard { model.connectedServices.relay }

    var body: some View {
        Form {
            Section {
                if let error = board.readError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if let relay = board.relay {
                    rows(relay)
                    PluginSettingRows(selection: .eventRelay)
                } else if board.readError == nil {
                    ProgressView()
                }
            } header: {
                Text("Relay")
            } footer: {
                Text("A Doorstep relay receives webhooks for this account and forwards them to this server, so "
                    + "the server needs no public address.")
                    .foregroundStyle(.secondary)
            }
            EventSourceSection()
        }
        .formStyle(.grouped)
        .task(id: board.watchKey) { await model.watchEventRelay() }
        .eventSourceSheet()
    }

    @ViewBuilder private func rows(_ relay: EventRelay) -> some View {
        @Bindable var board = board
        LabeledContent("Status") {
            HStack(spacing: 6) {
                if board.isSaving || relay.status == .connecting { ProgressView().controlSize(.small) }
                Text(board.isSaving ? "Saving…" : relay.statusLabel)
                    .foregroundStyle(relay.status == .error ? .red : .secondary)
            }
        }
        TextField("Relay URL", text: $board.url, prompt: Text("https://relay.example.com"))
            .accessibilityLabel("Relay URL")
            .autocorrectionDisabled()
            .disabled(board.isSaving)
            .onSubmit { model.saveEventRelay() }
        if let error = board.saveError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        if let error = relay.error {
            ServiceAlert(title: "Relay needs attention", message: error)
        }
        Button("Save") { model.saveEventRelay() }.disabled(!board.canSave)
    }
}
