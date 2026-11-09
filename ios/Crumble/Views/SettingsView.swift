import apfelkern
import BotAvatar
import SwiftUI

/// Everything that isn't a conversation: the account, the theme, notifications, and every
/// workspace page and connected service.
struct SettingsView: View {
  private struct Page {
    let route: Route
    let symbol: String
    let color: Color
  }

  private static let workspace: [Page] = [
    .init(route: .memory, symbol: "brain", color: .pink),
    .init(route: .skills, symbol: "book.closed.fill", color: .orange),
    .init(route: .automations, symbol: "calendar.badge.clock", color: .red),
    .init(route: .activity, symbol: "waveform.path.ecg", color: .green),
    .init(route: .avatars, symbol: "face.smiling", color: .yellow),
    .init(route: .judgeModel, symbol: JudgeModelSettings.symbol, color: .indigo),
    .init(route: .visionModel, symbol: VisionModelSettings.symbol, color: .purple),
    .init(route: .integrations, symbol: "powerplug.fill", color: .teal),
    .init(route: .coding, symbol: "chevron.left.forwardslash.chevron.right", color: .gray),
    .init(route: .users, symbol: "person.2.fill", color: .blue)
  ]

  private static let connectedServices: [Page] = [
    .init(route: .providers, symbol: "key.radiowaves.forward.fill", color: .blue),
    .init(route: .passwordManagers, symbol: "lock.rectangle.stack.fill", color: .gray),
    .init(route: .credentials, symbol: "key.fill", color: .yellow),
    .init(route: .logins, symbol: "person.badge.key.fill", color: .green),
    .init(route: .webSearch, symbol: "globe", color: .cyan),
    .init(route: .messageGateways, symbol: "message.fill", color: .mint),
    .init(route: .eventRelay, symbol: "dot.radiowaves.left.and.right", color: .orange)
  ]

  private func pageRow(_ page: Page) -> some View {
    Button {
      model.navigate(to: page.route)
      close()
    } label: {
      HStack {
        SettingsLabel(title: page.route.title, symbol: page.symbol, color: page.color)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .foregroundStyle(.primary)
  }

  private var accountLink: some View {
    let account = model.adminBoard.account
    return Section {
      NavigationLink {
        AccountSettingsView()
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            Text(account.flatMap { $0.name.isEmpty ? nil : $0.name } ?? "Account").font(.headline)
            Text(account?.email ?? model.serverURL)
              .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
    }
  }

  private var themeSection: some View {
    Section {
      Picker(selection: Binding(get: { model.themeBoard.theme }, set: { model.chooseTheme($0) })) {
        ForEach(AppTheme.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
      } label: {
        SettingsLabel(title: "Theme", symbol: "circle.lefthalf.filled", color: .indigo)
      }
      .accessibilityIdentifier("theme")
      NavigationLink {
        NotificationSettingsView()
      } label: {
        SettingsLabel(title: "Notifications", symbol: "bell.badge.fill", color: .red)
      }
    }
  }

  private var signInSection: some View {
    @Bindable var model = model
    @Bindable var board = model.accountBoard
    let signingUp = board.mode == .signUp
    return Section {
      ServerURLField()
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
        SessionFootnote()
      }
      .foregroundStyle(.secondary)
    }
  }

  @Environment(AppModel.self) private var model
  /// Leaves Settings for the page just chosen, where the page doesn't push over it.
  var close: () -> Void = {}

  var body: some View {
    Form {
      SheetError()
      if model.isSignedIn {
        accountLink
      } else {
        signInSection
      }
      themeSection
      if model.isSignedIn {
        Section("Workspace") {
          ForEach(Self.workspace.filter { $0.route != .users || model.adminBoard.isAdmin }, id: \.route) {
            pageRow($0)
          }
        }
        Section("Connected services") {
          ForEach(Self.connectedServices, id: \.route) { pageRow($0) }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
  }
}

/// A title beside its icon on a colored tile, as in the iOS Settings app.
private struct SettingsLabel: View {
  let title: String
  let symbol: String
  let color: Color

  var body: some View {
    Label {
      Text(title)
    } icon: {
      SettingsIcon(symbol: symbol, color: color)
    }
  }
}

/// A symbol on a colored tile, as in the iOS Settings app.
struct SettingsIcon: View {
  let symbol: String
  let color: Color

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: 29, height: 29)
      .background(color, in: .rect(cornerRadius: 7, style: .continuous))
  }
}

private struct ServerURLField: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    TextField("Server URL", text: $model.serverURL, prompt: Text("http://192.168.1.10:7337"))
      .accessibilityIdentifier("serverURL")
      .keyboardType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
  }
}

private struct SessionFootnote: View {
  var body: some View {
    Text(
      """
      Your session is stored securely on this device and never written to the project. For a physical \
      iPhone, use your Mac’s LAN address instead of 127.0.0.1.
      """)
  }
}

/// Who is signed in, the server, and passkeys.
private struct AccountSettingsView: View {
  @Environment(AppModel.self) private var model

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

  private var serverSection: some View {
    Section {
      ServerURLField()
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
      SessionFootnote().foregroundStyle(.secondary)
    }
  }

  var body: some View {
    Form {
      SheetError()
      accountSection
      serverSection
      if model.isSignedIn {
        PasskeysSection(board: model.passkeyBoard, client: model.client)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: model.client?.token) { model.loadPasskeys() }
  }
}

private struct NotificationSettingsView: View {
  var body: some View {
    Form {
      Section {
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
    .formStyle(.grouped)
    .navigationTitle("Notifications")
    .navigationBarTitleDisplayMode(.inline)
  }
}
