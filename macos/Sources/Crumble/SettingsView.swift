import AppKit
import apfelkern
import BotAvatar
import SwiftUI

/// What the provider key form follows.
private struct ProviderKeySource: Equatable {
    var provider: String
    var status: ProviderStatus?
}

struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            SheetError()
            themeSection
            notificationsSection
            serverSection
            providerSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.client?.token) { _, token in
            if token?.isEmpty == false { model.loadProviders() }
        }
        .onAppear {
            if model.client?.token.isEmpty == false { model.loadProviders() }
        }
    }

    private var themeSection: some View {
        Section {
            Picker(
                "Theme",
                selection: Binding(get: { model.themeBoard.theme }, set: { model.chooseTheme($0) })
            ) {
                ForEach(AppTheme.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
        }
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

    @ViewBuilder private var serverSection: some View {
        if model.isSignedIn {
            accountSection
            connectedServerSection
        } else {
            signInSection
        }
    }

    private var accountSection: some View {
        let account = model.adminBoard.account
        return Section("Account") {
            LabeledContent(
                account.flatMap { $0.name.isEmpty ? nil : $0.name } ?? "Signed in", value: account?.email ?? "")
            HStack {
                Button("Sign Out") { model.signOut() }
                    .disabled(model.accountBoard.isSigningOut || model.savingConnection)
                if model.accountBoard.isSigningOut {
                    ProgressView().controlSize(.small)
                    Text("Signing out…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectedServerSection: some View {
        @Bindable var model = model
        return Section {
            TextField("Server URL", text: $model.serverURL, prompt: Text("http://127.0.0.1:7337"))
            HStack {
                Button("Connect") { model.saveSettings() }
                    .disabled(model.savingConnection || model.accountBoard.isSigningOut)
                if model.savingConnection {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Your session stays in the macOS Keychain; it is never written to the project.").foregroundStyle(
                .secondary)
        }
    }

    private var signInSection: some View {
        @Bindable var model = model
        @Bindable var board = model.accountBoard
        let signingUp = board.mode == .signUp
        return Section {
            TextField("Server URL", text: $model.serverURL, prompt: Text("http://127.0.0.1:7337"))
                .onChange(of: model.serverURL) { board.takeInvite(from: &model.serverURL) }
            if board.invite != nil {
                LabeledContent("Invite") {
                    HStack {
                        Text("Link added")
                        Button("Remove") { board.removeInvite() }
                    }
                }
            }
            if signingUp {
                TextField("Name", text: $board.name, prompt: Text("Required"))
                    .textContentType(.name)
            }
            TextField("Email", text: $board.email, prompt: Text("Required"))
                .textContentType(.username)
            SecureField("Password", text: $board.password, prompt: Text("Required"))
                .textContentType(signingUp ? .newPassword : .password)
            HStack {
                Button(signingUp ? "Create Account" : "Sign In") { model.saveSettings() }
                    .disabled(model.savingConnection)
                if model.savingConnection {
                    ProgressView().controlSize(.small)
                    Text(signingUp ? "Creating account…" : "Signing in…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(signingUp ? "Already have an account? Sign In" : "Create an Account") { board.switchMode() }
                    .buttonStyle(.link)
                    .disabled(model.savingConnection)
            }
        } header: {
            Text("Server")
        } footer: {
            Text(
                """
                To join with an invite link, paste it into Server URL. Your session stays in the macOS Keychain; it is \
                never written to the project.
                """
            ).foregroundStyle(.secondary)
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
            if model.providers.isEmpty {
                TextField("Provider", text: $model.provider, prompt: Text("melious"))
            } else {
                Picker(selection: $model.provider) {
                    ForEach(model.providers, id: \.provider) { Text($0.provider).tag($0.provider) }
                } label: {
                    Label {
                        Text("Provider")
                    } icon: {
                        BrandLogoView(.provider(id: model.provider, name: status?.name ?? model.provider))
                    }
                }
            }
            if let saved = status?.savedLabel(managers: model.connectedServices.passwordManagers.managers) {
                LabeledContent("Saved", value: saved)
            }
            if offersKey {
                SecretSourceField(label: "API key", source: Bindable(key).source, prompt: "Paste a key")
            }
            if !key.saveError.isEmpty {
                Text(key.saveError).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if offersKey { Button("Save Key") { model.saveProviderKey() }.disabled(!key.canSave) }
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
        .task(id: ProviderKeySource(provider: model.provider, status: status)) {
            key.show(provider: model.provider, status: status)
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
