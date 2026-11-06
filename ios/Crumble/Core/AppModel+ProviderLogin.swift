import apfelkern
import Foundation

extension AppModel {
  // MARK: Provider sign-in

  var providerLogins: [String: ProviderLogin] { providerLoginBoard.logins }
  var providerLoginRequests: Set<String> { providerLoginBoard.requests }
  var providerLoginOutcomes: [String: String] { providerLoginBoard.outcomes }

  /// Starts an account or API-key sign-in on the server.
  func startProviderLogin(_ provider: String, method: ProviderAuthType) {
    guard let client else { return }
    providerLoginBoard.start(provider, method: method, client: client)
  }

  func answerProviderLogin(_ login: ProviderLogin, promptID: String, value: String) {
    guard let client else { return }
    providerLoginBoard.answer(login, promptID: promptID, value: value, client: client)
  }

  func cancelProviderLogin(_ login: ProviderLogin) {
    guard let client else { return }
    providerLoginBoard.cancel(login, client: client)
  }

  func resumeProviderLogins() {
    guard let client else { return }
    providerLoginBoard.resume(providers, client: client)
  }

  func handleProviderLogin(_ event: ProviderLoginBoard.Event) {
    switch event {
    case let .signedIn(provider):
      let name = providers.first { $0.provider == provider }?.name ?? provider
      showNotice("Signed in to \(name)")
      refreshProviders()
    case .providersChanged:
      refreshProviders()
    case let .failed(message):
      errorText = message
    }
  }
}
