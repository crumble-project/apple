import apfelkern

extension AppModel: GroupChatHost {
  /// Where the open conversation's optimistic messages live.
  var conversationKey: String {
    selectedGroupID.isEmpty ? selectedAgentID : GroupChat.deliveryKey(selectedGroupID)
  }

  func leaveBotChat() {
    cancelStream()
    updateSelectedAgent("")
    snapshot = nil
  }
}
