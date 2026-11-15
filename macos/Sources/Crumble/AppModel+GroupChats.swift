import apfelkern

extension AppModel: GroupChatHost {
    func leaveBotChat() {
        rememberSelectedChat()
        cancelStream()
        selectedAgentID = ""
        snapshot = nil
    }
}
