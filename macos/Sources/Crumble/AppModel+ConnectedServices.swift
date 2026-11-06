import apfelkern

extension AppModel {
    func loadConnectedServices(_ route: Route) {
        guard let client else { return }
        connectedServices.refresh(route, client: client)
    }

    func loadPasswordManagers() {
        guard let client else { return }
        connectedServices.passwordManagers.refresh(client: client)
    }

    func savePasswordManagerDraft() {
        guard let client else { return }
        connectedServices.passwordManagers.saveDraft(client: client)
    }

    func disconnectPasswordManager(_ manager: PasswordManager) {
        guard let client else { return }
        connectedServices.passwordManagers.disconnect(manager, client: client)
    }

    func savePluginSettingDraft() {
        guard let client else { return }
        connectedServices.pluginSettings.saveDraft(client: client)
    }

    func removePluginSetting(_ setting: PluginSetting) {
        guard let client else { return }
        connectedServices.pluginSettings.remove(setting, client: client)
    }

    func chooseAccountSetting<Setting>(_ choice: Setting.Choice, on board: AccountSettingBoard<Setting>) {
        guard let client else { return }
        board.choose(choice, client: client)
    }

    func watchMessageGateways() async {
        guard let client else { return }
        await connectedServices.gateways.watch(client: client)
    }

    func saveGatewayDraft() {
        guard let client else { return }
        connectedServices.gateways.saveDraft(bots: agents, client: client)
    }

    func watchEventRelay() async {
        guard let client else { return }
        await connectedServices.relay.watch(client: client)
    }

    func saveEventRelay() {
        guard let client else { return }
        connectedServices.relay.save(client: client)
    }

    func saveEventSourceDraft() {
        guard let client else { return }
        connectedServices.eventSources.saveDraft(client: client)
    }

    func deleteEventSource(_ source: EventSource) {
        guard let client else { return }
        connectedServices.eventSources.delete(source, client: client)
    }
}
