import SwiftUI

/// Server connection and provider API keys.
struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var model = model
    let configured = model.providers.filter(\.configured).map(\.provider)
    NavigationStack {
      Form {
        SheetError()
        Section {
          TextField("Server URL", text: $model.serverURL, prompt: Text("http://192.168.1.10:7337"))
            .accessibilityIdentifier("serverURL")
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Server token", text: $model.token, prompt: Text("Server token"))
            .accessibilityIdentifier("serverToken")
            .accessibilityLabel("Server token")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          HStack {
            Button("Save Connection") { model.saveSettings() }
              .disabled(model.savingConnection)
            if model.savingConnection {
              ProgressView()
              Text("Connecting…").foregroundStyle(.secondary)
            }
          }
        } header: {
          Text("Server")
        } footer: {
          Text(
            "The token is stored securely on this device and never written to the project. For a physical iPhone, use your Mac’s LAN address instead of 127.0.0.1."
          ).foregroundStyle(.secondary)
        }
        Section("Notifications") {
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
        Section {
          if model.client?.token.isEmpty != false {
            Text("Save a server connection above before managing provider keys.")
              .foregroundStyle(.secondary)
          }
          if model.providers.isEmpty {
            TextField("Provider", text: $model.provider, prompt: Text("melious"))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          } else {
            Picker("Provider", selection: $model.provider) {
              ForEach(model.providers, id: \.provider) { Text($0.provider).tag($0.provider) }
            }
          }
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
