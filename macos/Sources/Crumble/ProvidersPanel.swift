import AppKit
import apfelkern
import BotAvatar
import SwiftUI

/// What the provider key form follows.
private struct ProviderKeySource: Equatable {
    var provider: String
    var status: ProviderStatus?
}

private struct EditedProvider: Identifiable {
    let id: String
}

struct ProvidersPanel: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var editing: EditedProvider?

    var body: some View {
        ProviderList(
            providers: model.providers, managers: model.connectedServices.passwordManagers.managers, query: query,
            edit: {
                model.provider = $0.provider
                editing = EditedProvider(id: $0.provider)
            },
            copy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString($0, forType: .string)
                model.showNotice("Copied")
            }
        )
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: "Search providers")
        .sheet(item: $editing) { _ in ProviderFormView() }
    }
}

private struct ProviderFormView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let status = model.providers.first { $0.provider == model.provider }
        let key = model.providerKeyBoard
        let busy = model.pendingMutations.contains("provider:\(model.provider)") || key.isSaving
        let offersKey = status.map { $0.authMethods.contains { $0.type == .apiKey } } ?? true
        let accountMethods = status?.authMethods.filter { $0.type == .oauth } ?? []
        Form {
            SheetError()
            Section {
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
                Label {
                    Text(status?.displayName ?? model.provider)
                } icon: {
                    BrandLogoView(.provider(id: model.provider, name: status?.displayName ?? model.provider))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
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
