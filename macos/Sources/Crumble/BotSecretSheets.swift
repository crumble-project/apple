import apfelkern
import SwiftUI

/// Adds or edits a credential or login. What the owner typed lives on the board until the sheet
/// closes, and never comes back from the server.
private struct BotSecretSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: BotSecretDraft

    private var board: BotSecretBoard { model.botSecretBoard }

    var body: some View {
        NavigationStack {
            Form {
                if let reason = draft.request?.reason {
                    Section { Text(reason).foregroundStyle(.secondary) }
                }
                status
                if draft.choosesBot {
                    Section {
                        Picker("For bot", selection: $draft.agentID) {
                            ForEach(model.agents) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                nameAndHosts
                if draft.kind == .credential {
                    Section {
                        SecretSourceField(label: "Value", source: $draft.value, managers: board.connectedManagers)
                    }
                } else {
                    loginSource
                }
            }
            .formStyle(.grouped)
            .disabled(board.isSaving)
            .navigationTitle(draft.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { board.closeDraft() }
                        .disabled(board.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.existing == nil ? "Add" : "Save") { model.saveBotSecretDraft() }
                        .disabled(!board.canSave)
                }
            }
        }
        .frame(width: 480, height: 560)
        .interactiveDismissDisabled(board.isSaving)
    }

    @ViewBuilder private var status: some View {
        if board.isSaving {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            }
        } else if !board.saveError.isEmpty {
            Section {
                Label(board.saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var nameAndHosts: some View {
        Group {
            Section {
                TextField("Name", text: $draft.name, prompt: Text(draft.namePlaceholder))
                    .accessibilityLabel("Name")
                    .autocorrectionDisabled()
                    .disabled(draft.nameLocked)
                    .foregroundStyle(draft.nameLocked ? .secondary : .primary)
            } header: {
                Text("Name")
            } footer: {
                if let error = draft.nameError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(draft.nameNote).foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Hosts", text: $draft.hosts, prompt: Text(draft.hostsPlaceholder))
                    .accessibilityLabel("Hosts")
                    .autocorrectionDisabled()
            } header: {
                Text("Hosts")
            } footer: {
                Text(draft.hostsNote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var loginSource: some View {
        if board.connectedManagers.contains(where: { $0.id == .onePassword }) {
            Section {
                Picker("How the login is filled", selection: $draft.usesItem) {
                    Text("Fields").tag(false)
                    Text("1Password item").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
        if draft.usesItem {
            Section {
                TextField("Item", text: $draft.item, prompt: Text("op://vault/item"))
                    .accessibilityLabel("Item")
                    .autocorrectionDisabled()
                    .fontDesign(.monospaced)
            } footer: {
                Text("Fills the item's username, password, and one-time code, if it has one. "
                    + "Crumble checks it can read them when you save.")
                    .foregroundStyle(.secondary)
            }
        } else {
            loginFields
        }
    }

    private var loginFields: some View {
        Group {
            Section {
                SecretSourceField(
                    label: "Username", source: $draft.username, managers: board.connectedManagers, concealed: false)
            }
            Section {
                SecretSourceField(
                    label: "Password", source: $draft.password, managers: board.connectedManagers,
                    valueNote: "Stored encrypted and never shown again. Desktop jobs fill it without seeing it.")
            }
            Section {
                Toggle("One-time code", isOn: $draft.hasCode)
                if draft.hasCode {
                    SecretSourceField(
                        label: "One-time code secret", source: $draft.oneTimeCode, managers: board.connectedManagers,
                        valueNote: "The setup key or otpauth:// URI from the site's two-factor setup. "
                            + "Crumble computes each code from it.")
                }
            }
        }
    }
}

/// One secret: typed here, or read from a connected password manager.
struct SecretSourceField: View {
    let label: String
    @Binding var source: SecretSourceDraft
    var managers: [PasswordManager] = []
    var concealed = true
    var valueNote: String?
    var placeholder: String?
    /// Overrides every other prompt for a value, for forms where empty doesn't keep what's saved.
    var prompt: String?
    @Environment(AppModel.self) private var model
    @State private var connecting = false

    /// The board's answer wins once it has one: a password manager connected from here shows at once.
    private var available: [PasswordManager] {
        model.connectedServices.passwordManagers.connected(knownUntilLoaded: managers)
    }

    var body: some View {
        if !available.isEmpty, source.manager == nil || available.contains(where: { $0.id == source.manager }) {
            Picker("Where \(label.lowercased()) comes from", selection: manager) {
                Text("Crumble").tag(PasswordManagerID?.none)
                ForEach(available) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.segmented)
        }
        field.task { model.loadPasswordManagers() }
        Text(source.note(managers: available, valueNote: valueNote))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        if available.isEmpty, source.manager == nil {
            Button("Connect a password manager") { connecting = true }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .sheet(isPresented: $connecting) { PasswordManagersSheet() }
        }
    }

    private var valuePrompt: String { prompt ?? source.keepPlaceholder.nilIfEmpty ?? placeholder ?? label }

    private var manager: Binding<PasswordManagerID?> {
        Binding(get: { source.manager }, set: { source.use($0) })
    }

    @ViewBuilder private var field: some View {
        if let manager = source.manager {
            TextField(label, text: $source.reference, prompt: Text(manager.referencePlaceholder))
                .accessibilityLabel(label)
                .autocorrectionDisabled()
                .fontDesign(.monospaced)
        } else if concealed {
            SecureField(label, text: $source.value, prompt: Text(valuePrompt))
                .accessibilityLabel(label)
                .privacySensitive()
        } else {
            TextField(label, text: $source.value, prompt: Text(valuePrompt))
                .accessibilityLabel(label)
                .autocorrectionDisabled()
                .privacySensitive()
        }
    }
}

private struct BotSecretUsesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let log: BotSecretUseLog

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(log.uses) { use in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(use.summary).font(.system(size: 13)).lineLimit(2)
                            HStack {
                                Text(activityTime(use.usedAt))
                                Spacer(minLength: 8)
                                if let outcome = use.outcome {
                                    Text(outcome).foregroundStyle(use.failed ? Color.red : Color.secondary)
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        }
                    }
                    if !log.error.isEmpty {
                        Text(log.error).foregroundStyle(.red).textSelection(.enabled)
                    } else if log.uses.isEmpty, !log.loading {
                        Text(log.target.kind.usesEmptyText).foregroundStyle(.secondary)
                    }
                    if log.loading {
                        ProgressView()
                    } else if log.hasMore, !log.uses.isEmpty {
                        Button("Load More") { model.loadMoreBotSecretUses(log) }
                    }
                } footer: {
                    Text(log.target.kind.usesDescription).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(log.target.kind.usesTitle(log.target.name))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 520, height: 420)
    }
}

/// Presents the board's sheets. Only one presenter may be `active`: the root, or the bot editor
/// while it covers the root.
private struct BotSecretSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    private var board: BotSecretBoard { model.botSecretBoard }

    private var draft: Binding<BotSecretDraft?> {
        Binding(
            get: { active ? board.draft : nil },
            set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
    }

    private var useLog: Binding<BotSecretUseLog?> {
        Binding(get: { active ? board.useLog : nil }, set: { board.useLog = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: draft) { BotSecretSheet(draft: sheetBinding(draft, for: $0)) }
            .sheet(item: useLog) { BotSecretUsesView(log: $0) }
    }
}

extension View {
    func botSecretSheets(active: Bool) -> some View {
        modifier(BotSecretSheets(active: active))
    }
}
