import apfelkern

extension AppModel {
  func loadAccount() {
    guard let client else { return }
    serverAccountBoard.loadAccount(client: client)
    themeBoard.refresh(client: client)
  }

  func chooseTheme(_ theme: AppTheme) {
    themeBoard.choose(theme, client: isSignedIn ? client : nil) { [weak self] in self?.errorText = $0 }
  }

  var commandPalette: CommandPalette {
    CommandPalette(
      bots: agents, groups: groupChats, pending: pendingMutations, isSignedIn: isSignedIn, theme: themeBoard.theme)
  }

  func loadPasskeys() {
    guard let client, isSignedIn else { return }
    passkeyBoard.refresh(client: client)
  }
}
