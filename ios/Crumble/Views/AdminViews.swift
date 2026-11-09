import apfelkern
import SwiftUI

/// The Users page. Only an admin gets past the notice, as on the web.
struct UsersPanel: View {
  @Environment(AppModel.self) private var model

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    Form {
      if board.isAdmin {
        UsersSection()
        SignUpSection()
      } else {
        Section("Users") {
          if let error = board.accountError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
          } else if board.isAccountLoaded {
            Text("Only admins manage users.").foregroundStyle(.secondary)
          } else {
            ProgressView()
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct UsersSection: View {
  @Environment(AppModel.self) private var model

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    Section("Users") {
      if let error = board.usersError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if !board.isLoaded { ProgressView() }
      ForEach(board.users) { UserRow(user: $0) }
      ForEach(board.invites) { InviteRow(invite: $0) }
      Button("Invite", systemImage: "person.badge.plus") { model.createInvite() }
        .disabled(board.inviteSheet != nil)
    }
  }
}

private struct UserRow: View {
  @Environment(AppModel.self) private var model
  let user: AdminUser
  @State private var confirmingRemove = false

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    HStack {
      Text(user.initial)
        .fontWeight(.semibold)
        .frame(width: 28, height: 28)
        .background(.quaternary, in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(user.title).lineLimit(1)
        if let error = board.errors[user.id] {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      Spacer()
      if board.isUnconfirmed(user) {
        ProgressView()
      } else if board.canManage(user) {
        Menu {
          if user.role == .admin {
            Button("Make regular user", systemImage: "shield.slash") { model.setUserRole(.user, for: user) }
          } else {
            Button("Make admin", systemImage: "checkmark.shield") { model.setUserRole(.admin, for: user) }
          }
          Button("Remove account and data", systemImage: "trash", role: .destructive) {
            confirmingRemove = true
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
          .accessibilityLabel("Actions for \(user.shown)")
      }
    }
    .confirmationDialog("Remove \(user.shown)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
      Button("Remove account and data", role: .destructive) { model.removeUser(user) }
    } message: {
      Text(user.removeWarning)
    }
  }
}

private struct InviteRow: View {
  @Environment(AppModel.self) private var model
  let invite: PendingInvite

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    HStack {
      Image(systemName: "link")
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(invite.title)
        if let error = board.errors[invite.id] {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      Spacer()
      Button("Revoke") { model.revokeInvite(invite) }
    }
  }
}

private struct SignUpSection: View {
  @Environment(AppModel.self) private var model

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    Section("Sign-up") {
      if let settings = board.settings {
        Toggle(
          "Open sign-up",
          isOn: Binding(get: { settings.signUpOpen }, set: { model.setSignUpOpen($0) }))
          .disabled(board.isSavingSignUp)
      } else if !board.isLoaded {
        ProgressView()
      }
      if let error = board.signUpError ?? board.settingsError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
    }
  }
}

/// The Coding page: Workspaces, then the GitHub identities bots work as, in the web's order.
struct CodingPanel: View {
  var body: some View {
    Form {
      WorkspaceSettingsSection()
      GitHubAppsSection()
      MachineAccountsSection()
    }
    .formStyle(.grouped)
  }
}

/// An account that isn't an admin sees this only for what the server lacks, as on the web.
private struct WorkspaceSettingsSection: View {
  @Environment(AppModel.self) private var model

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    let notes = model.capabilities?.missingNotes ?? []
    if board.isAdmin || !notes.isEmpty {
      Section("Workspaces") {
        ForEach(notes, id: \.self) { note in
          Text(note).fontDesign(.monospaced).font(.caption).foregroundStyle(.secondary)
        }
        if board.isAdmin {
          adminRows
        }
      }
    }
    if board.isAdmin, !board.outdatedWorkspaces.isEmpty {
      outdated
    }
  }

  @ViewBuilder private var adminRows: some View {
    if let settings = board.settings {
      ForEach(ServerSettingsDraft.Field.allCases) { field in
        HStack {
          Label(field.title, systemImage: field.symbol)
          Spacer()
          Text(field.value(settings)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          Button("Edit") { board.edit(field) }
            .accessibilityLabel("Edit \(field.title)")
        }
      }
    } else if !board.isLoaded {
      ProgressView()
    }
    if let error = board.settingsError {
      Text(error).foregroundStyle(.red).textSelection(.enabled)
    }
  }

  private var outdated: some View {
    Section {
      ForEach(board.outdatedWorkspaces) { workspace in
        LabeledContent(
          model.agents.first { $0.id == workspace.agentId }?.name ?? workspace.agentId,
          value: board.owner(of: workspace) ?? workspace.userId)
      }
    } header: {
      Text("Outdated workspaces")
    } footer: {
      Text("These run another image than the settings name. Each switches at its next idle stop, "
        + "keeping its files.")
        .foregroundStyle(.secondary)
    }
  }
}

/// Edits one workspace setting. Saving shows at once and reopens this with the error on failure.
private struct ServerSettingsSheet: View {
  @Environment(AppModel.self) private var model
  @Binding var draft: ServerSettingsDraft

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    NavigationStack {
      Form {
        if !board.saveError.isEmpty {
          Section {
            Text(board.saveError).foregroundStyle(.red).textSelection(.enabled)
          }
        }
        Section { fields }
      }
      .formStyle(.grouped)
      .navigationTitle(draft.field.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) { board.closeDraft() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .confirm) { model.saveServerSettingsDraft() }
            .disabled(!draft.isReady)
        }
      }
    }
  }

  @ViewBuilder private var fields: some View {
    switch draft.field {
    case .size:
      number("CPUs", text: $draft.cpus, keyboard: .numberPad)
      number("Memory (GB)", text: $draft.memory, keyboard: .decimalPad)
    case .image:
      TextField("Image", text: $draft.image, prompt: Text("ghcr.io/owner/image:tag"))
        .fontDesign(.monospaced)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityLabel("Image")
    case .grace:
      number("Minutes", text: $draft.grace, keyboard: .numberPad)
    }
  }

  /// A form field shows its title only while empty; these need it beside their value.
  private func number(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
    LabeledContent(title) {
      TextField(title, text: text)
        .keyboardType(keyboard)
        .multilineTextAlignment(.trailing)
    }
  }
}

/// Shows a new invite link once: the server keeps only its hash.
private struct InviteLinkSheetView: View {
  @Environment(AppModel.self) private var model
  let sheet: InviteLinkSheet

  private var board: AdminBoard { model.adminBoard }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let link = sheet.link {
            Text(link)
              .fontDesign(.monospaced)
              .font(.system(size: 12))
              .lineLimit(3)
              .textSelection(.enabled)
              .privacySensitive()
            Button("Copy Link") { copyLocally(link) }
          } else if let error = sheet.error {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
          } else {
            HStack(spacing: 8) {
              ProgressView()
              Text("Creating link…").foregroundStyle(.secondary)
            }
          }
        } footer: {
          Text("Anyone with this link can create one account. It's shown only now.")
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Invite link")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .close) { board.closeInviteSheet() }
        }
      }
    }
  }
}

private struct AdminSheetsModifier: ViewModifier {
  @Environment(AppModel.self) private var model

  private var board: AdminBoard { model.adminBoard }

  private var draft: Binding<ServerSettingsDraft?> {
    Binding(
      get: { board.draft },
      set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
  }

  private var invite: Binding<InviteLinkSheet?> {
    Binding(
      get: { board.inviteSheet },
      set: { if $0 == nil { board.closeInviteSheet() } })
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: draft) { ServerSettingsSheet(draft: sheetBinding(draft, for: $0)) }
      .sheet(item: invite) { sheet in
        InviteLinkSheetView(sheet: board.inviteSheet ?? sheet)
      }
  }
}

extension View {
  func adminSheets() -> some View {
    modifier(AdminSheetsModifier())
  }
}
