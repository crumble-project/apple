import apfelkern
import BotAvatar
import SwiftUI

/// Server connection, theme, notifications, and passkeys.
struct SettingsView: View {
  @ViewBuilder private var serverSection: some View {
    if model.isSignedIn {
      accountSection
      connectedServerSection
    } else {
      signInSection
    }
  }

  private var themeSection: some View {
    Section {
      Picker("Theme", selection: Binding(get: { model.themeBoard.theme }, set: { model.chooseTheme($0) })) {
        ForEach(AppTheme.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
      }
      .accessibilityIdentifier("theme")
    }
  }

  private var accountSection: some View {
    let account = model.adminBoard.account
    return Section("Account") {
      LabeledContent(account.flatMap { $0.name.isEmpty ? nil : $0.name } ?? "Signed in", value: account?.email ?? "")
      HStack {
        Button("Sign Out") { model.signOut() }
          .disabled(model.accountBoard.isSigningOut || model.savingConnection)
        if model.accountBoard.isSigningOut {
          ProgressView()
          Text("Signing out…").foregroundStyle(.secondary)
        }
      }
    }
  }

  private var serverURLField: some View {
    @Bindable var model = model
    return TextField("Server URL", text: $model.serverURL, prompt: Text("http://192.168.1.10:7337"))
      .accessibilityIdentifier("serverURL")
      .keyboardType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
  }

  private var sessionFootnote: Text {
    Text(
      """
      Your session is stored securely on this device and never written to the project. For a physical \
      iPhone, use your Mac’s LAN address instead of 127.0.0.1.
      """)
  }

  private var connectedServerSection: some View {
    Section {
      serverURLField
      HStack {
        Button("Connect") { model.saveSettings() }
          .disabled(model.savingConnection || model.accountBoard.isSigningOut)
        if model.savingConnection {
          ProgressView()
          Text("Connecting…").foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Server")
    } footer: {
      sessionFootnote.foregroundStyle(.secondary)
    }
  }

  private var signInSection: some View {
    @Bindable var model = model
    @Bindable var board = model.accountBoard
    let signingUp = board.mode == .signUp
    return Section {
      serverURLField
        .onChange(of: model.serverURL) { board.takeInvite(from: &model.serverURL) }
      if board.invite != nil {
        LabeledContent("Invite") {
          HStack {
            Text("Link added")
            Button("Remove") { board.removeInvite() }
              .buttonStyle(.borderless)
          }
        }
      }
      if signingUp {
        TextField("Name", text: $board.name, prompt: Text("Name"))
          .accessibilityIdentifier("name")
          .textContentType(.name)
      }
      TextField("Email", text: $board.email, prompt: Text("Email"))
        .accessibilityIdentifier("email")
        .keyboardType(.emailAddress)
        .textContentType(.username)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      SecureField("Password", text: $board.password, prompt: Text("Password"))
        .accessibilityIdentifier("password")
        .textContentType(signingUp ? .newPassword : .password)
      HStack {
        Button(signingUp ? "Create Account" : "Sign In") { model.saveSettings() }
          .disabled(model.savingConnection)
        if model.savingConnection {
          ProgressView()
          Text(signingUp ? "Creating account…" : "Signing in…").foregroundStyle(.secondary)
        }
      }
      Button(signingUp ? "Already have an account? Sign In" : "Create an Account") { board.switchMode() }
        .disabled(model.savingConnection)
    } header: {
      Text("Server")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("To join with an invite link, paste it into Server URL.")
        sessionFootnote
      }
      .foregroundStyle(.secondary)
    }
  }

  private var notificationsSection: some View {
    @Bindable var model = model
    return Section("Notifications") {
      Toggle("Reply notifications", isOn: Binding(
        get: { PushController.shared.enabled },
        set: { Notifier.shared.setEnabled($0) }))
      Text(PushController.shared.status).font(.footnote).foregroundStyle(.secondary)
      if PushController.shared.badgesOff {
        Text("Turn on Badges in iOS Settings to count unread replies on the app icon.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Button("Open iOS Notification Settings") {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
    }
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        SheetError()
        serverSection
        if model.isSignedIn {
          PasskeysSection(board: model.passkeyBoard, client: model.client)
        }
        themeSection
        notificationsSection
      }
      .formStyle(.grouped)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task(id: model.client?.token) { model.loadPasskeys() }
    }
  }
}
