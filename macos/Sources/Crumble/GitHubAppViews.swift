import AppKit
import apfelkern
import SwiftUI

/// The GitHub Apps section of the Coding page.
struct GitHubAppsSection: View {
    @Environment(AppModel.self) private var model

    private var board: GitHubAppBoard { model.gitHubAppBoard }

    var body: some View {
        Section {
            if let error = board.readError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if board.isLoaded, board.apps.isEmpty {
                Text("No GitHub Apps yet.").foregroundStyle(.secondary)
            }
            ForEach(board.apps) { GitHubAppRow(app: $0) }
            if board.creation == nil, board.draft == nil { GitHubTripRow() }
            Button("New GitHub App", systemImage: "plus") { board.startNew() }
        } header: {
            Text("GitHub Apps")
        } footer: {
            Text("Each App is a GitHub identity in one account. Bots assigned to it push, commit, and open pull "
                + "requests as it there.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Shows a step in the browser is pending, and lets the owner stop waiting for it.
private struct GitHubTripRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let trip = model.gitHubAppBoard.trip {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(trip.progressText).foregroundStyle(.secondary)
                Spacer()
                Button("Stop Waiting") { model.stopWaitingForGitHub() }
            }
            if let note = trip.browserNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GitHubAppRow: View {
    @Environment(AppModel.self) private var model
    let app: GitHubApp
    @State private var confirmingRemove = false

    private var board: GitHubAppBoard { model.gitHubAppBoard }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.login).fontWeight(.semibold).lineLimit(1)
                Text(app.usedByText).font(.caption).foregroundStyle(.secondary)
                if let error = board.errors[app.id] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            if board.isUnconfirmed(app) { ProgressView().controlSize(.small) }
            buttons
        }
        .disabled(board.isUnconfirmed(app))
        .confirmationDialog("Remove \(app.login)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.removeGitHubApp(app) }
        } message: {
            Text(app.removeWarning)
        }
    }

    @ViewBuilder private var buttons: some View {
        if !app.installed {
            Button("Install") { model.installGitHubApp(app) }
                .disabled(!board.canLeave)
        }
        Button("Edit") { model.editGitHubApp(app) }
        Button("Remove") { confirmingRemove = true }
    }
}

/// Starts a new App. GitHub creates it, so the sheet stays until the server has it.
private struct NewGitHubAppSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: NewGitHubAppDraft

    private var board: GitHubAppBoard { model.gitHubAppBoard }

    var body: some View {
        NavigationStack {
            Form {
                status
                fields.disabled(board.isOpening || board.trip != nil)
            }
            .formStyle(.grouped)
            .navigationTitle("New GitHub App")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { board.closeNew() }
                        .disabled(board.isOpening)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create on GitHub") { model.createGitHubApp() }
                        .disabled(!draft.isReady || !board.canLeave)
                }
            }
        }
        .frame(width: 480, height: 620)
        .interactiveDismissDisabled(board.isOpening || board.trip != nil)
    }

    @ViewBuilder private var fields: some View {
        Section {
            Text("GitHub opens to create a private App on one account. Bots you assign to it commit and "
                + "open pull requests as it in that account's repositories.")
                .foregroundStyle(.secondary)
        }
        Section {
            TextField("Name", text: $draft.name, prompt: Text("frien-bot"))
        } footer: {
            Text("Unique across GitHub. Commits show it as name[bot].").foregroundStyle(.secondary)
        }
        Section {
            TextField("Organization", text: $draft.organization, prompt: Text("Your account"))
        } footer: {
            Text("The App can only work in its owner's repositories. Create one App per account.")
                .foregroundStyle(.secondary)
        }
        GitHubWebPageNote()
    }

    @ViewBuilder private var status: some View {
        if board.isOpening {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening GitHub…")
                }
            }
        } else if board.trip != nil {
            Section { GitHubTripRow() }
        } else if !board.saveError.isEmpty {
            Section {
                Label(board.saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

/// GitHub returns to the server's web page, and that page needs its own sign-in in the browser.
private struct GitHubWebPageNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let url = model.gitHubWebSignInURL {
                Link("Sign In to the Web Page", destination: url)
            }
        } footer: {
            Text("GitHub returns to this server's web page, which finishes the step, so sign in there in your "
                + "browser first. Otherwise GitHub's answer is lost.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Edits one App. A typed client secret lives on the board until the sheet closes.
private struct GitHubAppSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: GitHubAppDraft

    private var board: GitHubAppBoard { model.gitHubAppBoard }
    private var app: GitHubApp { draft.app }
    private var busy: Bool { board.checking.contains(app.id) }

    var body: some View {
        NavigationStack {
            Form {
                status
                if let url = URL(string: app.htmlUrl) {
                    Section { Link("Open on GitHub", destination: url) }
                }
                installation
                actsAs
                bots
            }
            .formStyle(.grouped)
            .disabled(board.isSaving)
            .navigationTitle(app.login)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { board.closeDraft() }
                        .disabled(board.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveGitHubAppDraft() }
                        .disabled(!board.canSave)
                }
            }
        }
        .frame(width: 480, height: 620)
        .interactiveDismissDisabled(board.isSaving)
    }

    @ViewBuilder private var status: some View {
        if board.trip != nil {
            Section { GitHubTripRow() }
        }
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
        if let error = board.errors[app.id] {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var installation: some View {
        Section {
            Text(app.installationText)
            if !app.installed {
                Button("Install") { model.installGitHubApp(app) }
                    .disabled(!board.canLeave)
            }
            Button("Check") { model.connectGitHubApp(app) }
                .disabled(busy)
        } header: {
            Text("Installation")
        }
    }

    @ViewBuilder private var actsAs: some View {
        Section {
            Text(app.actsAsText)
            if app.user != nil {
                Button("Sign Out") { model.signOutOfGitHubApp(app) }
                    .disabled(busy)
            } else {
                if app.clientSecret.configured {
                    Button("Sign In as Me") { model.signInToGitHubApp(app) }
                        .disabled(!board.canLeave)
                }
                if let url = model.gitHubCallbackURL {
                    LabeledContent("Callback URL") {
                        Text(url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Button("Copy Callback URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                if !app.clientSecret.configured {
                    SecretSourceField(
                        label: "Client secret", source: $draft.clientSecret, managers: board.connectedManagers,
                        valueNote: "To let bots act as you, open the App's settings on GitHub, add the callback "
                            + "URL above, and generate a client secret.")
                    Button("Save Client Secret") { model.saveGitHubAppClientSecret() }
                        .disabled(!draft.canSaveClientSecret || board.isSaving)
                }
            }
        } header: {
            Text("Bots act as")
        } footer: {
            if app.user != nil {
                Text(app.signedInNote).foregroundStyle(.secondary)
            }
        }
        if app.user == nil, app.clientSecret.configured { GitHubWebPageNote() }
    }

    private var bots: some View {
        Section {
            ForEach(model.agents) { agent in
                Toggle(agent.name, isOn: assigned(agent.id))
            }
        } header: {
            Text("Bots")
        } footer: {
            Text("They get GH_TOKEN once the App is installed. A bot uses one App per GitHub account; its first "
                + "App is its default for commits and gh pr.")
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
}

private struct GitHubAppSheetsModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    private var board: GitHubAppBoard { model.gitHubAppBoard }

    private var creation: Binding<NewGitHubAppDraft?> {
        Binding(
            get: { board.creation },
            set: { if $0 == nil { board.closeNew() } else { board.creation = $0 } })
    }

    private var draft: Binding<GitHubAppDraft?> {
        Binding(
            get: { board.draft },
            set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: board.trip?.id) { _, _ in
                if let trip = board.trip { NSWorkspace.shared.open(trip.url) }
            }
            .sheet(item: creation) { NewGitHubAppSheet(draft: sheetBinding(creation, for: $0)) }
            .sheet(item: draft) { GitHubAppSheet(draft: sheetBinding(draft, for: $0)) }
    }
}

extension View {
    func gitHubAppSheets() -> some View {
        modifier(GitHubAppSheetsModifier())
    }
}
