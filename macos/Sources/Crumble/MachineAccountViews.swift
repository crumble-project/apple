import apfelkern
import SwiftUI

/// The Machine accounts section of the Integrations page.
struct MachineAccountsSection: View {
    @Environment(AppModel.self) private var model

    private var board: GitHubAccountBoard { model.gitHubAccountBoard }

    var body: some View {
        Section {
            if let error = board.readError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if board.isLoaded, board.accounts.isEmpty {
                Text("No machine accounts yet.").foregroundStyle(.secondary)
            }
            ForEach(board.accounts) { MachineAccountRow(account: $0) }
            Button("New Machine Account", systemImage: "plus") { model.newGitHubAccount() }
        } header: {
            Text("Machine accounts")
        } footer: {
            Text("GitHub users for your bots to act as wherever none of their Apps does.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct MachineAccountRow: View {
    @Environment(AppModel.self) private var model
    let account: GitHubAccount
    @State private var confirmingRemove = false

    private var board: GitHubAccountBoard { model.gitHubAccountBoard }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.login).fontWeight(.semibold).lineLimit(1)
                Text(account.usedByText).font(.caption).foregroundStyle(.secondary)
                if let error = board.errors[account.id] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            if board.isUnconfirmed(account) { ProgressView().controlSize(.small) }
            Button("Edit") { model.editGitHubAccount(account) }
            Button("Remove") { confirmingRemove = true }
        }
        .disabled(board.isUnconfirmed(account))
        .confirmationDialog("Remove \(account.login)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.removeGitHubAccount(account) }
        } message: {
            Text(account.removeWarning)
        }
    }
}

/// Adds a machine account or edits one. A typed token lives on the board until the sheet closes.
private struct MachineAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: GitHubAccountDraft

    private var board: GitHubAccountBoard { model.gitHubAccountBoard }

    var body: some View {
        NavigationStack {
            Form {
                status
                if let account = draft.existing {
                    identity(account)
                    bots
                    token
                    signingKey(account)
                } else {
                    Section {
                        Text("A GitHub user you made for your bots. They act as it wherever none of their Apps does, "
                            + "such as other people's repositories.")
                            .foregroundStyle(.secondary)
                    }
                    token
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
                    Button(draft.existing == nil ? "Add" : "Save") { model.saveGitHubAccountDraft() }
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

    @ViewBuilder private func identity(_ account: GitHubAccount) -> some View {
        if let url = URL(string: account.htmlUrl) {
            Section { Link("Open on GitHub", destination: url) }
        }
    }

    private var bots: some View {
        Section {
            ForEach(model.agents) { agent in
                Toggle(agent.name, isOn: assigned(agent.id))
            }
        } header: {
            Text("Bots")
        } footer: {
            Text("They get GH_TOKEN and act as this user wherever none of their Apps does; their commits default "
                + "to it. A bot acts as one machine account.")
                .foregroundStyle(.secondary)
        }
    }

    private func assigned(_ botID: String) -> Binding<Bool> {
        Binding(
            get: { draft.botIDs.contains(botID) },
            set: { assigned in
                if assigned { draft.botIDs.insert(botID) } else { draft.botIDs.remove(botID) }
            })
    }

    private var token: some View {
        Section {
            SecretSourceField(
                label: draft.tokenLabel, source: $draft.token, managers: board.connectedManagers,
                valueNote: "Signed in as the machine account on GitHub, create a personal access token with "
                    + "access to the repositories its bots work in.",
                placeholder: "github_pat_…")
            if draft.token.manager == nil, let url = GitHubAccount.newTokenURL {
                Link("New Token", destination: url)
            }
        }
    }

    private func signingKey(_ account: GitHubAccount) -> some View {
        Section {
            Text(account.signingKey)
                .fontDesign(.monospaced)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Copy Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.signingKey, forType: .string)
            }
            if let url = GitHubAccount.addSigningKeyURL {
                Link("Add Key on GitHub", destination: url)
            }
        } header: {
            Text("Signing key")
        } footer: {
            Text(account.signingKeyNote).foregroundStyle(.secondary)
        }
    }
}

private struct MachineAccountSheetModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    private var board: GitHubAccountBoard { model.gitHubAccountBoard }

    private var draft: Binding<GitHubAccountDraft?> {
        Binding(
            get: { board.draft },
            set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
    }

    func body(content: Content) -> some View {
        content.sheet(item: draft) { MachineAccountSheet(draft: sheetBinding(draft, for: $0)) }
    }
}

extension View {
    func machineAccountSheet() -> some View {
        modifier(MachineAccountSheetModifier())
    }
}
