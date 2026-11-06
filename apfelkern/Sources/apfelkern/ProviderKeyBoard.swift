import Foundation
import Observation

/// The API key form for the chosen provider. A typed key clears at once and comes back if the save
/// fails. A password manager reference waits for the server, which reads it before it answers.
/// Results that return after the connection changed are dropped.
@MainActor @Observable
public final class ProviderKeyBoard {
  public var source = SecretSourceDraft()
  public private(set) var isSaving = false
  public private(set) var saveError = ""
  private var provider = ""
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    source = SecretSourceDraft()
    isSaving = false
    saveError = ""
    provider = ""
  }

  /// Follows the provider picker and the server's answers, without touching what the owner typed.
  public func show(provider: String, status: ProviderStatus?) {
    guard provider != self.provider || (source.changedInput == nil && source.saved != status?.apiKey) else { return }
    if provider != self.provider { saveError = "" }
    self.provider = provider
    source = SecretSourceDraft(saved: status?.apiKey)
  }

  private var input: SecretInput? {
    guard case .value(let value)? = source.changedInput else { return source.changedInput }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map(SecretInput.value)
  }

  public var canSave: Bool { !isSaving && !provider.isEmpty && input != nil }

  /// `saved` runs once the server has the key.
  public func save(client: APIClient, saved: @escaping @MainActor () -> Void) {
    guard canSave, let input else { return }
    let typed = source
    let target = provider
    let version = scope
    isSaving = true
    saveError = ""
    if case .value = input { source = SecretSourceDraft(saved: typed.saved) }
    Task {
      do {
        try await client.setProviderKey(target, secret: input)
        guard scope == version else { return }
        isSaving = false
        if case .reference(let manager, let reference) = input, provider == target {
          source = SecretSourceDraft(
            saved: SecretStatus(configured: true, passwordManager: manager, reference: reference))
        }
        saved()
      } catch {
        guard scope == version else { return }
        isSaving = false
        if provider == target, source.input == nil || source.changedInput == typed.changedInput { source = typed }
        saveError = friendlyError(error)
      }
    }
  }
}

extension ProviderStatus {
  /// What the Providers section says is saved, naming the password manager a key is read from.
  public func savedLabel(managers: [PasswordManager]) -> String? {
    switch credentialType {
    case .oauth: return "Account sign-in"
    case .apiKey:
      guard let manager = apiKey.passwordManager else { return "API key" }
      return "API key in " + (managers.first { $0.id == manager }?.name ?? "a password manager")
    case nil: return nil
    }
  }
}
