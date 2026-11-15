import apfelkern

extension AppModel: GroupChatHost {
  func leaveBotChat() {
    cancelStream()
    updateSelectedAgent("")
    snapshot = nil
  }
}
