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
        UIPasteboard.general.string = $0
        model.showNotice("Copied")
      }
    )
    .formStyle(.grouped)
    .searchable(text: $query, placement: .automatic, prompt: "Search providers")
    .sheet(item: $editing) { _ in ProviderFormView() }
  }
}

private struct ProviderFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  private var status: ProviderStatus? { model.providers.first { $0.provider == model.provider } }

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        keySection
      }
      .formStyle(.grouped)
      .navigationTitle(status?.displayName ?? model.provider)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .close) { dismiss() }
        }
      }
    }
    .task(id: ProviderKeySource(provider: model.provider, status: status)) {
      model.providerKeyBoard.show(provider: model.provider, status: status)
    }
  }

  private var keySection: some View {
    let key = model.providerKeyBoard
    let busy = model.pendingMutations.contains("provider:\(model.provider)") || key.isSaving
    let offersKey = status.map { $0.authMethods.contains { $0.type == .apiKey } } ?? true
    let accountMethods = status?.authMethods.filter { $0.type == .oauth } ?? []
    return Section {
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
    } footer: {
      Text("Keys and account sign-ins are stored encrypted on your server and shared by its bots.")
        .foregroundStyle(.secondary)
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
}
