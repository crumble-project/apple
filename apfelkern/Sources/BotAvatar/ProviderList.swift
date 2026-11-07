import apfelkern
import SwiftUI

/// The Providers page: those set up, then the rest, narrowed by a search. Choosing a row opens its
/// key and sign-in form. A provider a command-line tool signs in to has no form, only the command.
public struct ProviderList: View {
  private let all: [ProviderStatus]
  private let managers: [PasswordManager]
  private let query: String
  private let edit: (ProviderStatus) -> Void
  private let copy: (String) -> Void

  public init(
    providers: [ProviderStatus], managers: [PasswordManager], query: String,
    edit: @escaping (ProviderStatus) -> Void, copy: @escaping (String) -> Void
  ) {
    all = providers
    self.managers = managers
    self.query = query
    self.edit = edit
    self.copy = copy
  }

  public var body: some View {
    let shown = providers(all, matching: query)
    let ready = shown.filter(\.configured)
    let available = shown.filter { !$0.configured }
    if all.isEmpty {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if shown.isEmpty {
      ContentUnavailableView(
        "No providers match", systemImage: "magnifyingglass", description: Text("Try another name."))
    } else {
      Form {
        if !ready.isEmpty {
          Section {
            ForEach(ready, id: \.provider, content: row)
          } header: {
            Text("Set up")
          } footer: {
            Text(
              "Bots use these providers' models. Keys and sign-ins are stored encrypted on the server and "
                + "shared by every bot."
            )
            .foregroundStyle(.secondary)
          }
        }
        if !available.isEmpty {
          Section(ready.isEmpty ? "Providers" : "Available") {
            ForEach(available, id: \.provider, content: row)
          }
        }
      }
    }
  }

  @ViewBuilder private func row(_ provider: ProviderStatus) -> some View {
    if let external = provider.externalAuth {
      HStack {
        summary(provider)
        if let action = external.copyAction {
          Menu {
            Button(action.label, systemImage: "doc.on.doc") { copy(action.command) }
              .help(action.command)
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .buttonStyle(.borderless)
          .fixedSize()
          .accessibilityLabel("\(provider.displayName) actions")
        }
      }
    } else {
      Button {
        edit(provider)
      } label: {
        summary(provider).contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
  }

  private func summary(_ provider: ProviderStatus) -> some View {
    HStack(spacing: 10) {
      BrandLogoView(.provider(id: provider.provider, name: provider.displayName))
      VStack(alignment: .leading, spacing: 2) {
        Text(provider.displayName)
        if let method = provider.authMethods.first(where: { $0.type == .oauth })?.label {
          Text(method).font(.caption).foregroundStyle(.secondary)
        }
        if let problem = provider.externalAuth?.problem {
          Text(problem).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      Spacer()
      if let status = provider.statusLabel(managers: managers) {
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
