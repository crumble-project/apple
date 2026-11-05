import apfelkern

extension AppModel: GroupChatHost {
    func leaveBotChat() {
        cancelStream()
        selectedAgentID = ""
        snapshot = nil
    }
}
