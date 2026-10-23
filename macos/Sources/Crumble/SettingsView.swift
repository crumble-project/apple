import AppKit
import apfelkern
import SwiftUI

struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            SheetError()
            notificationsSection
            serverSection
            providerSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.loadProviders() }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(
                "Notifications",
                isOn: Binding(
                    get: { model.notifier.enabled }, set: { model.notifier.enabled = $0 }))
            Text(model.notifier.status).font(.caption).foregroundStyle(.secondary)
            Button("Open Notification Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } header: {
            Text("Notifications")
        }
    }

    private var serverSection: some View {
        @Bindable var model = model
        return Section {
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
            Text("The token stays in the macOS Keychain; it is never written to the project.").foregroundStyle(
                .secondary)
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
            if model.providers.isEmpty {
                TextField("Provider", text: $model.provider, prompt: Text("melious"))
            } else {
                Picker("Provider", selection: $model.provider) {
                    ForEach(model.providers, id: \.provider) { Text($0.provider).tag($0.provider) }
                }
            }
            if let credential = status?.credentialType {
                LabeledContent("Saved", value: credential == .oauth ? "Account sign-in" : "API key")
            }
            if offersKey {
                SecureField("API key", text: $model.providerKey, prompt: Text("Paste a key"))
            }
            HStack {
                if offersKey { Button("Save Key") { model.saveProviderKey() } }
                Button(status?.credentialType == .oauth ? "Sign Out" : "Remove Key", role: .destructive) {
                    model.removeProviderKey()
                }
                if busy {
                    ProgressView().controlSize(.small)
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
                    + "Keys and account sign-ins are stored encrypted on your Crumble server and shared by its bots."
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func providerLogin(_ methods: [ProviderLoginMethod]) -> some View {
        let provider = model.provider
        if let login = model.providerLogins[provider] {
            ProviderLoginView(login: login)
        } else if !methods.isEmpty {
            let starting = model.providerLoginRequests.contains(provider)
            HStack {
                ForEach(methods, id: \.label) { method in
                    Button(method.label) { model.startProviderLogin(provider, method: method.type) }
                }
                if starting {
                    ProgressView().controlSize(.small)
                    Text("Starting sign-in…").foregroundStyle(.secondary)
                }
            }
            .disabled(starting)
        }
        if let outcome = model.providerLoginOutcomes[provider] {
            Text(outcome).foregroundStyle(.red)
        }
    }
}
