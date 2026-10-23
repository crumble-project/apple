import apfelkern
import Foundation

extension AppModel {
    // MARK: Provider sign-in

    /// Starts an account or API-key sign-in on the server. Success shows only once the server saved the credential.
    func startProviderLogin(_ provider: String, method: ProviderAuthType) {
        guard let client, providerLogins[provider]?.isPending != true,
            providerLoginRequests.insert(provider).inserted
        else { return }
        let generation = generation
        providerLoginOutcomes[provider] = nil
        Task {
            defer { if self.generation == generation { providerLoginRequests.remove(provider) } }
            do {
                let login = try await client.startProviderLogin(provider, method: method)
                guard self.generation == generation else { return }
                applyProviderLogin(login)
            } catch {
                guard self.generation == generation else { return }
                providerLoginOutcomes[provider] = friendlyError(error)
                // A sign-in already running, perhaps from another client, is picked up instead.
                loadProviders()
            }
        }
    }

    func answerProviderLogin(_ login: ProviderLogin, promptID: String, value: String) {
        sendProviderLogin(login) { try await $0.answerProviderLogin(login.id, promptID: promptID, value: value) }
    }

    func cancelProviderLogin(_ login: ProviderLogin) {
        sendProviderLogin(login) { try await $0.cancelProviderLogin(login.id) }
    }

    /// Picks up sign-ins still running on the server, such as after reconnecting or from another client.
    func resumeProviderLogins() {
        guard let client else { return }
        let generation = generation
        for status in providers {
            guard let id = status.activeLoginId, providerLogins[status.provider]?.id != id else { continue }
            Task {
                guard let login = try? await client.providerLogin(id), self.generation == generation else { return }
                applyProviderLogin(login)
            }
        }
    }

    func resetProviderLogins() {
        for poll in providerLoginPolls.values { poll.cancel() }
        providerLoginPolls = [:]
        providerLogins = [:]
        providerLoginRequests = []
        providerLoginOutcomes = [:]
    }

    private func sendProviderLogin(
        _ login: ProviderLogin, _ work: @escaping @MainActor (APIClient) async throws -> ProviderLogin
    ) {
        guard let client, providerLoginRequests.insert(login.provider).inserted else { return }
        let generation = generation
        Task {
            defer { if self.generation == generation { providerLoginRequests.remove(login.provider) } }
            do {
                let next = try await work(client)
                guard self.generation == generation else { return }
                applyProviderLogin(next)
            } catch {
                guard self.generation == generation else { return }
                if (error as? APIError)?.statusCode == 410 {
                    endProviderLogin(login, outcome: "This sign-in ended on the server. Start again.")
                } else {
                    errorText = friendlyError(error)
                }
            }
        }
    }

    private func applyProviderLogin(_ login: ProviderLogin) {
        let provider = login.provider
        if let current = providerLogins[provider], current.id != login.id, current.isPending { return }
        switch login.status {
        case .pending:
            providerLogins[provider] = login
            pollProviderLogin(login)
        case .succeeded:
            endProviderLogin(login, outcome: nil)
            let name = providers.first { $0.provider == provider }?.name ?? provider
            showNotice("Signed in to \(name)")
            loadProviders()
        case .failed:
            endProviderLogin(login, outcome: login.failure ?? "Sign-in failed. Try again.")
        case .expired:
            endProviderLogin(login, outcome: "Sign-in expired. Start again.")
        case .cancelled:
            endProviderLogin(login, outcome: nil)
            loadProviders()
        }
    }

    private func endProviderLogin(_ login: ProviderLogin, outcome: String?) {
        guard providerLogins[login.provider].map({ $0.id == login.id }) ?? true else { return }
        providerLoginPolls.removeValue(forKey: login.provider)?.cancel()
        providerLogins[login.provider] = nil
        providerLoginOutcomes[login.provider] = outcome
    }

    /// Follows a pending sign-in. Connection errors keep it, so it continues after the server is reachable again.
    private func pollProviderLogin(_ login: ProviderLogin) {
        guard providerLoginPolls[login.provider] == nil, let client else { return }
        let generation = generation
        providerLoginPolls[login.provider] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.generation == generation,
                    providerLogins[login.provider]?.id == login.id
                else { return }
                do {
                    let next = try await client.providerLogin(login.id)
                    guard !Task.isCancelled, self.generation == generation else { return }
                    applyProviderLogin(next)
                    if !next.isPending { return }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == generation else { return }
                    if (error as? APIError)?.statusCode == 410 {
                        endProviderLogin(login, outcome: "This sign-in ended on the server. Start again.")
                        return
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}
