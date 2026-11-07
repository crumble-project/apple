import apfelkern

extension AppModel {
  func refreshBotRequestsIfChanged() {
    guard let client else { return }
    botRequestBoard.refreshIfChanged(messages: messages, client: client)
  }

  func watchBotRequests() async {
    guard let client, botRequestBoard.needsPolling else { return }
    await botRequestBoard.watch(client: client)
  }

  /// The new bot joins the list at once; the reload picks up anything else the server set.
  func approveBotRequest(_ request: BotRequest, editedTo bot: Agent? = nil) {
    guard let client else { return }
    let connection = generation
    botRequestBoard.approve(request, editedTo: bot, client: client) { [self] agent in
      guard generation == connection else { return }
      if !agents.contains(where: { $0.id == agent.id }) { agents.append(agent) }
      if agentDraft?.botRequest?.id == request.id { agentDraft = nil }
      reconcileAgents()
    }
  }

  func declineBotRequest(_ request: BotRequest) {
    guard let client else { return }
    botRequestBoard.decline(request, client: client)
  }

  /// A card names the proposal's MCP servers, which the chat doesn't load on its own.
  func loadBotRequestServers(_ request: BotRequest) async {
    let missing = (request.proposal.mcpServers ?? []).filter { id in !mcpServers.contains { $0.id == id } }
    guard let client, !missing.isEmpty else { return }
    let connection = generation
    let revision = mutationRevision
    guard let loaded = try? await client.mcpServers(), generation == connection,
      mutationRevision == revision, pendingMutations.isEmpty else { return }
    mcpServers = loaded
  }
}
