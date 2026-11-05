import Foundation
import Observation

/// Provider sign-ins running on the server, by provider. Success shows only once the server saved the
/// credential. Results that return after `reset` are dropped.
@MainActor @Observable
public final class ProviderLoginBoard {
  public enum Event: Sendable {
    case signedIn(provider: String)
    /// The server's provider list may have changed.
    case providersChanged
    case failed(String)
  }

  public private(set) var logins: [String: ProviderLogin] = [:]
  /// Providers waiting for the server to start, answer, or cancel their sign-in.
  public private(set) var requests: Set<String> = []
  /// Why a provider's last sign-in ended without signing in.
  public private(set) var outcomes: [String: String] = [:]
  @ObservationIgnored private var polls: [String: Task<Void, Never>] = [:]
  private var scope = 0
  private let pollInterval: Duration
  private let onEvent: @MainActor (Event) -> Void

  public init(pollInterval: Duration = .seconds(1), onEvent: @escaping @MainActor (Event) -> Void) {
    self.pollInterval = pollInterval
    self.onEvent = onEvent
  }

  public func reset() {
    scope += 1
    for poll in polls.values { poll.cancel() }
    polls = [:]
    logins = [:]
    requests = []
    outcomes = [:]
  }

  public func start(_ provider: String, method: ProviderAuthType, client: APIClient) {
    guard logins[provider]?.isPending != true, requests.insert(provider).inserted else { return }
    let version = scope
    outcomes[provider] = nil
    Task {
      defer { if scope == version { requests.remove(provider) } }
      do {
        let login = try await client.startProviderLogin(provider, method: method)
        guard scope == version else { return }
        apply(login, client: client)
      } catch {
        guard scope == version else { return }
        outcomes[provider] = friendlyError(error)
        // A sign-in already running, perhaps from another client, is picked up instead.
        onEvent(.providersChanged)
      }
    }
  }

  public func answer(_ login: ProviderLogin, promptID: String, value: String, client: APIClient) {
    send(login, client: client) { try await $0.answerProviderLogin(login.id, promptID: promptID, value: value) }
  }

  public func cancel(_ login: ProviderLogin, client: APIClient) {
    send(login, client: client) { try await $0.cancelProviderLogin(login.id) }
  }

  /// Picks up sign-ins still running on the server, such as after reconnecting or from another client.
  public func resume(_ providers: [ProviderStatus], client: APIClient) {
    let version = scope
    for status in providers {
      guard let id = status.activeLoginId, logins[status.provider]?.id != id else { continue }
      Task {
        guard let login = try? await client.providerLogin(id), scope == version else { return }
        apply(login, client: client)
      }
    }
  }

  private func send(
    _ login: ProviderLogin, client: APIClient,
    _ work: @escaping @MainActor (APIClient) async throws -> ProviderLogin
  ) {
    guard requests.insert(login.provider).inserted else { return }
    let version = scope
    Task {
      defer { if scope == version { requests.remove(login.provider) } }
      do {
        let next = try await work(client)
        guard scope == version else { return }
        apply(next, client: client)
      } catch {
        guard scope == version else { return }
        if (error as? APIError)?.statusCode == 410 {
          end(login, outcome: "This sign-in ended on the server. Start again.")
        } else {
          onEvent(.failed(friendlyError(error)))
        }
      }
    }
  }

  private func apply(_ login: ProviderLogin, client: APIClient) {
    let provider = login.provider
    if let current = logins[provider], current.id != login.id, current.isPending { return }
    switch login.status {
    case .pending:
      logins[provider] = login
      poll(login, client: client)
    case .succeeded:
      end(login, outcome: nil)
      onEvent(.signedIn(provider: provider))
    case .failed:
      end(login, outcome: login.failure ?? "Sign-in failed. Try again.")
    case .expired:
      end(login, outcome: "Sign-in expired. Start again.")
    case .cancelled:
      end(login, outcome: nil)
      onEvent(.providersChanged)
    }
  }

  private func end(_ login: ProviderLogin, outcome: String?) {
    guard logins[login.provider].map({ $0.id == login.id }) ?? true else { return }
    polls.removeValue(forKey: login.provider)?.cancel()
    logins[login.provider] = nil
    outcomes[login.provider] = outcome
  }

  /// Follows a pending sign-in. Connection errors keep it, so it continues after the server is reachable again.
  private func poll(_ login: ProviderLogin, client: APIClient) {
    guard polls[login.provider] == nil else { return }
    let version = scope
    polls[login.provider] = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: pollInterval)
        guard !Task.isCancelled, scope == version, logins[login.provider]?.id == login.id else { return }
        do {
          let next = try await client.providerLogin(login.id)
          guard !Task.isCancelled, scope == version else { return }
          apply(next, client: client)
          if !next.isPending { return }
        } catch is CancellationError {
          return
        } catch {
          guard scope == version else { return }
          if (error as? APIError)?.statusCode == 410 {
            end(login, outcome: "This sign-in ended on the server. Start again.")
            return
          }
          try? await Task.sleep(for: pollInterval * 2)
        }
      }
    }
  }
}
