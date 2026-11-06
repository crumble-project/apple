import apfelkern

extension AppModel {
    func loadGitHubAccounts() {
        guard let client else { return }
        gitHubAccountBoard.refresh(client: client)
    }

    func newGitHubAccount() {
        guard let client else { return }
        gitHubAccountBoard.startNew(client: client)
    }

    func editGitHubAccount(_ account: GitHubAccount) {
        guard let client else { return }
        gitHubAccountBoard.edit(account, client: client)
    }

    func saveGitHubAccountDraft() {
        guard let client else { return }
        gitHubAccountBoard.saveDraft(client: client)
    }

    func removeGitHubAccount(_ account: GitHubAccount) {
        guard let client else { return }
        gitHubAccountBoard.remove(account, client: client)
    }
}
