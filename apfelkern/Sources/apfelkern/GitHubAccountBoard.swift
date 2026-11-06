import Foundation
import Observation

/// The owner's machine accounts and the sheet that edits one. Assigning bots and removing apply at
/// once; a failed assignment gives the sheet back. A token depends on GitHub, so the sheet holds
/// until the server answers. Results that return after the connection changed are dropped.
@MainActor @Observable
public final class GitHubAccountBoard {
  private var loaded: [GitHubAccount] = []
  public private(set) var isLoaded = false
  public private(set) var readError: String?
  private var reads = 0
  /// Reads up to this one are ignored: they may predate a newer read or a write.
  private var settledRead = 0
  /// Hidden from the list until the server answers, so a read can't bring them back.
  private var removing: Set<String> = []
  /// The bots to show for an account until the server answers, so a read can't take them away.
  private var assigning: [String: Set<String>] = [:]
  /// Why removing failed, by account.
  public private(set) var errors: [String: String] = [:]

  /// The open sheet. Only here, in a save in flight, and in `returned` does a typed token live.
  public var draft: GitHubAccountDraft?
  /// Failed saves waiting for the open sheet to close.
  private var returned: [(draft: GitHubAccountDraft, error: String)] = []
  /// The open sheet's token is with the server, so the sheet can't close until it answers.
  public private(set) var isSaving = false
  public private(set) var saveError = ""
  public private(set) var connectedManagers: [PasswordManager] = []
  private var scope = 0

  public init() {}

  public func reset() {
    scope += 1
    loaded = []
    isLoaded = false
    readError = nil
    reads = 0
    settledRead = 0
    removing = []
    assigning = [:]
    errors = [:]
    returned = []
    isSaving = false
    closeDraft()
    connectedManagers = []
  }

  public var accounts: [GitHubAccount] {
    loaded.filter { !removing.contains($0.id) }.map { account in
      var shown = account
      if let botIDs = assigning[account.id] { shown.botIds = botIDs.sorted() }
      return shown
    }
  }

  /// Its row shows bots the owner assigned, and the server hasn't answered yet.
  public func isUnconfirmed(_ account: GitHubAccount) -> Bool { assigning[account.id] != nil }

  public func refresh(client: APIClient) {
    let version = scope
    reads += 1
    let read = reads
    Task {
      do {
        let accounts = try await client.gitHubAccounts()
        guard scope == version, read > settledRead else { return }
        settledRead = read
        loaded = accounts
        isLoaded = true
        readError = nil
      } catch {
        guard scope == version, read > settledRead else { return }
        readError = friendlyError(error)
      }
    }
  }

  // MARK: Saving

  public func startNew(client: APIClient) {
    open(GitHubAccountDraft(), client: client)
  }

  public func edit(_ account: GitHubAccount, client: APIClient) {
    guard !isUnconfirmed(account) else { return }
    open(GitHubAccountDraft(existing: account), client: client)
  }

  /// Never replaces an open sheet: it may hold a typed token, or a save that came back.
  private func open(_ next: GitHubAccountDraft, client: APIClient) {
    guard draft == nil else { return }
    draft = next
    let version = scope
    Task {
      guard let managers = try? await client.passwordManagers(), scope == version else { return }
      connectedManagers = managers.filter(\.connected)
    }
  }

  public var canSave: Bool {
    guard let draft, draft.isReady, !isSaving else { return false }
    return draft.existing.map { !isUnconfirmed($0) } ?? true
  }

  public func closeDraft() {
    guard !isSaving else { return }
    draft?.clearSecrets()
    draft = nil
    saveError = ""
    if !returned.isEmpty {
      let next = returned.removeFirst()
      draft = next.draft
      saveError = next.error
    }
  }

  public func saveDraft(client: APIClient) {
    guard canSave, let draft else { return }
    saveError = ""
    if draft.checksToken {
      saveAfterCheck(draft, client: client)
    } else if draft.changesBots {
      assignAtOnce(draft, client: client)
    } else {
      closeDraft()
    }
  }

  private func saveAfterCheck(_ draft: GitHubAccountDraft, client: APIClient) {
    guard let input = draft.token.changedInput else { return }
    let version = scope
    isSaving = true
    Task {
      do {
        let saved = try await client.saveGitHubAccountToken(input, accountID: draft.existing?.id)
        guard scope == version else { return }
        store(saved)
        self.draft?.tokenSaved(saved)
        if draft.changesBots {
          let assigned = try await client.setGitHubAccountBots(accountID: saved.id, botIDs: draft.botIDs)
          guard scope == version else { return }
          store(assigned)
        }
        isSaving = false
        closeDraft()
      } catch {
        guard scope == version else { return }
        isSaving = false
        saveError = friendlyError(error)
      }
      refresh(client: client)
    }
  }

  private func assignAtOnce(_ draft: GitHubAccountDraft, client: APIClient) {
    guard let id = draft.existing?.id else { return }
    let version = scope
    assigning[id] = draft.botIDs
    closeDraft()
    Task {
      do {
        let assigned = try await client.setGitHubAccountBots(accountID: id, botIDs: draft.botIDs)
        guard scope == version else { return }
        store(assigned)
      } catch {
        guard scope == version else { return }
        settledRead = reads
        giveBack(draft, error: friendlyError(error))
      }
      assigning[id] = nil
      refresh(client: client)
    }
  }

  private func giveBack(_ failed: GitHubAccountDraft, error: String) {
    guard draft == nil else {
      returned.append((failed, error))
      return
    }
    draft = failed
    saveError = error
  }

  private func store(_ account: GitHubAccount) {
    settledRead = reads
    isLoaded = true
    if let index = loaded.firstIndex(where: { $0.id == account.id }) {
      loaded[index] = account
    } else {
      loaded.append(account)
    }
  }

  // MARK: Removing

  public func remove(_ account: GitHubAccount, client: APIClient) {
    guard !isUnconfirmed(account), removing.insert(account.id).inserted else { return }
    errors[account.id] = nil
    let version = scope
    Task {
      do {
        try await client.deleteGitHubAccount(accountID: account.id)
        guard scope == version else { return }
        loaded.removeAll { $0.id == account.id }
      } catch {
        guard scope == version else { return }
        errors[account.id] = friendlyError(error)
      }
      settledRead = reads
      removing.remove(account.id)
      refresh(client: client)
    }
  }
}
