import apfelkern

extension AppModel {
    func loadPasswordManagers() {
        guard let client else { return }
        connectedServices.passwordManagers.refresh(client: client)
    }
}
