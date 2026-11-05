import SwiftUI

/// Server connection and provider API keys.
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
    return Section {
      if model.client?.token.isEmpty != false {
        Text("Save a server connection above before managing provider keys.")
          .foregroundStyle(.secondary)
      }
      providerPicker
      SecureField(
        "Provider API key", text: $model.providerKey, prompt: Text("Provider API key")
      )
      .accessibilityLabel("Provider API key")
      HStack {
        Button("Save Key") { model.saveProviderKey() }
        Button("Remove Key", role: .destructive) { model.removeProviderKey() }
        if model.pendingMutations.contains("provider:\(model.provider)") {
          ProgressView()
          Text("Updating key…").foregroundStyle(.secondary)
        }
      }
      .disabled(model.pendingMutations.contains("provider:\(model.provider)"))
    } header: {
      Text("Provider API Keys")
    } footer: {
      Text(
        (configured.isEmpty ? "" : "Configured: " + configured.joined(separator: ", ") + ". ")
          + "Keys are stored encrypted on your server."
      )
      .foregroundStyle(.secondary)
    }
    .disabled(model.client?.token.isEmpty != false)
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
