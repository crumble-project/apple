import apfelkern

extension AppModel {
    func refreshBotSecretsIfChanged() {
        guard let client else { return }
        botSecretBoard.refreshIfChanged(messages: messages, client: client)
    }

    func watchBotSecrets() async {
        guard let client, botSecretBoard.needsPolling else { return }
        await botSecretBoard.watch(client: client)
    }

    func loadBotSecrets(agentID: String) {
        guard let client else { return }
        botSecretBoard.refresh(agentID: agentID, client: client)
    }

    func newBotSecret(_ kind: BotSecretKind, agentID: String) {
        guard let client else { return }
        botSecretBoard.startNew(kind, agentID: agentID, client: client)
    }

    func editBotSecret(_ item: BotSecret, agentID: String) {
        guard let client else { return }
        botSecretBoard.edit(item, agentID: agentID, client: client)
    }

    func addBotSecret(_ request: BotSecretRequest, kind: BotSecretKind, agentID: String) {
        guard let client else { return }
        botSecretBoard.add(request, kind: kind, agentID: agentID, client: client)
    }

    func saveBotSecretDraft() {
        guard let client else { return }
        botSecretBoard.saveDraft(client: client)
    }

    func deleteBotSecret(_ item: BotSecret, agentID: String) {
        guard let client else { return }
        botSecretBoard.delete(item, agentID: agentID, client: client)
    }

    func declineBotSecret(_ request: BotSecretRequest, kind: BotSecretKind, agentID: String) {
        guard let client else { return }
        botSecretBoard.decline(request, kind: kind, agentID: agentID, client: client)
    }

    func showBotSecretUses(_ item: BotSecret, agentID: String) {
        guard let client else { return }
        botSecretBoard.showUses(of: item, agentID: agentID, client: client)
    }

    func loadMoreBotSecretUses(_ log: BotSecretUseLog) {
        guard let client else { return }
        log.loadMore(client: client)
    }
}
