import apfelkern

extension AppModel {
  func refreshHeldActionsIfChanged() {
    guard let client else { return }
    heldActionBoard.refreshIfChanged(messages: messages, client: client)
  }

  func watchHeldActions() async {
    guard let client, heldActionBoard.needsPolling else { return }
    await heldActionBoard.watch(client: client)
  }

  func approveHeldAction(_ id: String) {
    guard let client else { return }
    heldActionBoard.approve(id, client: client)
  }

  func declineHeldAction(_ id: String) {
    guard let client else { return }
    heldActionBoard.decline(id, client: client)
  }
}
