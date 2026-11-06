import apfelkern
import BotAvatar
import SwiftUI

/// Server connection, provider API keys, and provider account sign-ins.
/// What the provider key form follows.
private struct ProviderKeySource: Equatable {
  var provider: String
  var status: ProviderStatus?
}

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
      Button("Open iOS Notification Settings") {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
    }
  }

  @ViewBuilder private var providerPicker: some View {
    @Bindable var model = model
    if model.providers.isEmpty {
      TextField("Provider", text: $model.provider, prompt: Text("melious"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    } else {
      Picker(selection: $model.provider) {
        ForEach(model.providers, id: \.provider) { Text($0.provider).tag($0.provider) }
      } label: {
        Label {
          Text("Provider")
        } icon: {
          BrandLogoView(.provider(
            id: model.provider,
            name: model.providers.first { $0.provider == model.provider }?.name ?? model.provider))
        }
      }
    }
  }

  private var providerSection: some View {
    @Bindable var model = model
    let configured = model.providers.filter(\.configured).map(\.provider)
    let status = model.providers.first { $0.provider == model.provider }
    let key = model.providerKeyBoard
    let busy = model.pendingMutations.contains("provider:\(model.provider)") || key.isSaving
    let offersKey = status.map { $0.authMethods.contains { $0.type == .apiKey } } ?? true
    let accountMethods = status?.authMethods.filter { $0.type == .oauth } ?? []
    return Section {
      if model.client?.token.isEmpty != false {
        Text("Save a server connection above before managing provider keys.")
          .foregroundStyle(.secondary)
      }
      providerPicker
      if let saved = status?.savedLabel(managers: model.connectedServices.passwordManagers.managers) {
        LabeledContent("Saved", value: saved)
      }
      if offersKey {
        SecretSourceField(
          label: "Provider API key", source: Bindable(key).source, prompt: "Provider API key")
      }
      if !key.saveError.isEmpty {
        Text(key.saveError).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        if offersKey { Button("Save Key") { model.saveProviderKey() }.disabled(!key.canSave) }
        Button(status?.credentialType == .oauth ? "Sign Out" : "Remove Key", role: .destructive) {
          model.removeProviderKey()
        }
        if busy {
          ProgressView()
          Text("Updating key…").foregroundStyle(.secondary)
        }
      }
      .disabled(busy)
      providerLogin(accountMethods)
    } header: {
      Text("Providers")
    } footer: {
      Text(
        (configured.isEmpty ? "" : "Configured: " + configured.joined(separator: ", ") + ". ")
          + "Keys and account sign-ins are stored encrypted on your server and shared by its bots."
      )
      .foregroundStyle(.secondary)
    }
    .disabled(model.client?.token.isEmpty != false)
    .task(id: ProviderKeySource(provider: model.provider, status: status)) {
      key.show(provider: model.provider, status: status)
    }
  }

  @ViewBuilder
  private func providerLogin(_ methods: [ProviderLoginMethod]) -> some View {
    let provider = model.provider
    if let login = model.providerLogins[provider] {
      ProviderLoginView(login: login).id(login.id)
    } else if !methods.isEmpty {
      let starting = model.providerLoginRequests.contains(provider)
      ForEach(methods, id: \.label) { method in
        Button(method.label) { model.startProviderLogin(provider, method: method.type) }
      }
      .disabled(starting)
      if starting {
        HStack {
          ProgressView()
          Text("Starting sign-in…").foregroundStyle(.secondary)
        }
      }
    }
    if let outcome = model.providerLoginOutcomes[provider] {
      Text(outcome).foregroundStyle(.red)
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
        themeSection
        notificationsSection
        providerSection
      }
      .formStyle(.grouped)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .onChange(of: model.client?.token) { _, token in
        if token?.isEmpty == false { model.loadProviders() }
      }
      .onAppear {
        if model.client?.token.isEmpty == false { model.loadProviders() }
      }
    }
  }
}
