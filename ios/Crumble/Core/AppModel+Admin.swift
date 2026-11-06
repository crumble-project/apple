import apfelkern

extension AppModel {
  func loadAccount() {
    guard let client else { return }
    adminBoard.loadAccount(client: client)
    themeBoard.refresh(client: client)
  }

  func chooseTheme(_ theme: AppTheme) {
    themeBoard.choose(theme, client: isSignedIn ? client : nil) { [weak self] in self?.errorText = $0 }
  }

  var commandPalette: CommandPalette {
    CommandPalette(
      bots: agents, groups: groupChats, pending: pendingMutations, isAdmin: adminBoard.isAdmin,
      isSignedIn: isSignedIn, theme: themeBoard.theme)
  }

  func loadAdmin() {
    guard let client else { return }
    adminBoard.refresh(client: client)
  }

  func setUserRole(_ role: UserRole, for user: AdminUser) {
    guard let client else { return }
    adminBoard.setRole(role, for: user, client: client)
  }

  func removeUser(_ user: AdminUser) {
    guard let client else { return }
    adminBoard.remove(user, client: client)
  }

  func createInvite() {
    guard let client else { return }
    adminBoard.createInvite(client: client)
  }

  func revokeInvite(_ invite: PendingInvite) {
    guard let client else { return }
    adminBoard.revoke(invite, client: client)
  }

  func setSignUpOpen(_ open: Bool) {
    guard let client else { return }
    adminBoard.setSignUpOpen(open, client: client)
  }

  func saveServerSettingsDraft() {
    guard let client else { return }
    adminBoard.saveDraft(client: client)
  }
}
