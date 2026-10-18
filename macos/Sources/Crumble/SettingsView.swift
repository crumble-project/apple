import SwiftUI

/// The app's Settings window (⌘,): the server connection and provider API keys.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let configured = model.providers.filter(\.configured).map(\.provider)
        Form {
            SheetError()
            Section {
                TextField("Server URL", text: $model.serverURL, prompt: Text("http://127.0.0.1:7337"))
                SecureField("Server token", text: $model.token, prompt: Text("Required"))
                HStack {
                    Button("Save Connection") { model.saveSettings() }
                        .disabled(model.savingConnection)
                    if model.savingConnection {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("The token stays in the macOS Keychain; it is never written to the project.").foregroundStyle(.secondary)
            }
            Section {
                if model.providers.isEmpty {
                    TextField("Provider", text: $model.provider, prompt: Text("melious"))
                } else {
                    Picker("Provider", selection: $model.provider) {
                        ForEach(model.providers, id: \.provider) { Text($0.provider).tag($0.provider) }
                    }
                }
                SecureField("API key", text: $model.providerKey, prompt: Text("Paste a key"))
                HStack {
                    Button("Save Key") { model.saveProviderKey() }
                    Button("Remove Key", role: .destructive) { model.removeProviderKey() }
                    if model.pendingMutations.contains("provider:\(model.provider)") {
                        ProgressView().controlSize(.small)
                        Text("Updating key…").foregroundStyle(.secondary)
                    }
                }
                .disabled(model.pendingMutations.contains("provider:\(model.provider)"))
            } header: {
                Text("Provider API Keys")
            } footer: {
                Text((configured.isEmpty ? "" : "Configured: " + configured.joined(separator: ", ") + ". ") + "Keys are stored encrypted on your server.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.loadProviders() }
    }
}
