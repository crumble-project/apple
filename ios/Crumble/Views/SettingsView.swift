import apfelkern
import SwiftUI

/// Server connection, provider API keys, and provider account sign-ins.
struct SettingsView: View {
  private var serverSection: some View {
    @Bindable var model = model
    return Section {
      TextField("Server URL", text: $model.serverURL, prompt: Text("http://192.168.1.10:7337"))
        .accessibilityIdentifier("serverURL")
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Email", text: $model.email, prompt: Text("Email"))
        .accessibilityIdentifier("email")
        .keyboardType(.emailAddress)
        .textContentType(.username)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      SecureField("Password", text: $model.password, prompt: Text("Password"))
        .accessibilityIdentifier("password")
        .textContentType(.password)
      HStack {
        Button("Sign In") { model.saveSettings() }
          .disabled(model.savingConnection)
        if model.savingConnection {
          ProgressView()
          Text("Signing in…").foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Server")
    } footer: {
      Text(
        """
        Your session is stored securely on this device and never written to the project. For a physical \
        iPhone, use your Mac’s LAN address instead of 127.0.0.1.
        """
      ).foregroundStyle(.secondary)
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
      Picker("Provider", selection: $model.provider) {
        ForEach(model.providers, id: \.provider) { Text($0.provider).tag($0.provider) }
      }
    }
  }

  private var providerSection: some View {
    @Bindable var model = model
    let configured = model.providers.filter(\.configured).map(\.provider)
    let status = model.providers.first { $0.provider == model.provider }
    let busy = model.pendingMutations.contains("provider:\(model.provider)")
    let offersKey = status.map { $0.authMethods.contains { $0.type == .apiKey } } ?? true
    let accountMethods = status?.authMethods.filter { $0.type == .oauth } ?? []
    return Section {
      if model.client?.token.isEmpty != false {
        Text("Save a server connection above before managing provider keys.")
          .foregroundStyle(.secondary)
      }
      providerPicker
      if let credential = status?.credentialType {
        LabeledContent("Saved", value: credential == .oauth ? "Account sign-in" : "API key")
      }
      if offersKey {
        SecureField(
          "Provider API key", text: $model.providerKey, prompt: Text("Provider API key")
        )
        .accessibilityLabel("Provider API key")
      }
      HStack {
        if offersKey { Button("Save Key") { model.saveProviderKey() } }
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
