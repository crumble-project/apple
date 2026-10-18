import AuthenticationServices
import Foundation
import SwiftUI

extension AppModel {
  /// Opens a server to edit, or a new one owned by `agentID` (nil for shared).
  func openMCPForm(_ id: String, agentID: String? = nil) {
    var form = MCPDraft(serverID: id, agentID: agentID)
    if let server = mcpServers.first(where: { $0.id == id }) {
      form.agentID = server.agentId
      form.name = server.name
      form.url = server.url
      form.enabled = server.enabled
    }
    mcpDraft = form
  }

  private func mcpInput(_ form: MCPDraft) -> (payload: [String: JSONValue], server: MCPServer)? {
    let name = form.name.trimmingCharacters(in: .whitespaces)
    let rawURL = form.url.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, let url = URL(string: rawURL), url.host() != nil,
      ["http", "https"].contains(url.scheme ?? "")
    else {
      errorText = "MCP name and an HTTP(S) URL are required."
      return nil
    }
    var payload: [String: JSONValue] = [
      "name": .string(name), "url": .string(rawURL), "enabled": .bool(form.enabled)
    ]
    if !form.token.isEmpty { payload["token"] = .string(form.token) }
    let isNew = form.serverID.isEmpty
    let provisionalID = isNew ? "pending-mcp-" + newRequestID() : form.serverID
    let old = mcpServers.first { $0.id == form.serverID }
    var provisional = MCPServer(
      id: provisionalID, name: name, url: rawURL, enabled: form.enabled, agentId: form.agentID,
      authenticated: false, auth: form.token.isEmpty ? "none" : "token")
    if let old, form.token.isEmpty, old.url == rawURL {
      provisional.authenticated = old.authenticated
      provisional.auth = old.auth
    }
    return (payload, provisional)
  }

  private func applyProvisionalMCP(_ provisional: MCPServer, form: MCPDraft) {
    let provisionalID = provisional.id
    let owner = form.agentID
    let isNew = form.serverID.isEmpty
    if let index = mcpServers.firstIndex(where: {
      $0.id == provisionalID || $0.id == form.serverID
    }) {
      mcpServers[index] = provisional
    } else {
      mcpServers.append(provisional)
    }
    if isNew, let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
      var memberships = agents[index].mcpServers ?? []
      if !memberships.contains(provisionalID) { memberships.append(provisionalID) }
      agents[index].mcpServers = memberships
    }
  }

  func saveMCP() {
    guard let form = mcpDraft else { return }
    guard let (initialPayload, provisional) = mcpInput(form) else { return }
    var payload = initialPayload
    let provisionalID = provisional.id
    let isNew = form.serverID.isEmpty
    let old = mcpServers.first { $0.id == form.serverID }
    let owner = form.agentID
    mcpDraft = nil
    optimisticMutation(
      key: "mcp:\(provisionalID)",
      update: { [self] in
        applyProvisionalMCP(provisional, form: form)
      },
      rollback: { [self] in
        rollbackMCP(provisionalID: provisionalID, form: form, old: old)
      },
      work: { client in
        if isNew {
          if let owner = form.agentID { payload["agentId"] = .string(owner) }
          let saved = try await client.createMCPServer(payload)
          return { [self] in
            if let index = mcpServers.firstIndex(where: { $0.id == provisionalID }) {
              mcpServers[index] = saved
            }
            if let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
              agents[index].mcpServers = (agents[index].mcpServers ?? []).map {
                $0 == provisionalID ? saved.id : $0
              }
            }
          }
        }
        let saved = try await client.updateMCPServer(form.serverID, patch: payload)
        return { [self] in
          if let index = mcpServers.firstIndex(where: { $0.id == provisionalID }) {
            mcpServers[index] = saved
          }
        }
      })
  }

  private func rollbackMCP(provisionalID: String, form: MCPDraft, old: MCPServer?) {
    let isNew = form.serverID.isEmpty
    let owner = form.agentID
    mcpServers.removeAll { $0.id == provisionalID }
    if let old { mcpServers.append(old) }
    if isNew, let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
      agents[index].mcpServers?.removeAll { $0 == provisionalID }
    }
    if route == .integrations, mcpDraft == nil { mcpDraft = form }
  }

  /// Where the system sign-in sheet returns; the sheet watches this scheme, so nothing registers it.
  static let oauthCallbackScheme = "dev.crumble.ios"
  static let oauthRedirectURI = oauthCallbackScheme + ":/oauth/callback"

  /// Signs in to an OAuth MCP server: the server prepares the request, the system sheet shows the
  /// provider's sign-in, and the server exchanges the returned code for tokens it keeps.
  func signInToMCP(_ id: String, using session: WebAuthenticationSession) async {
    guard let client else { return }
    errorText = ""
    signingIn = id
    let generationAtStart = generation
    defer { finishMCPSignIn(id, generation: generationAtStart) }
    do {
      let start = try await client.startMCPSignIn(id, redirectURI: Self.oauthRedirectURI)
      guard generation == generationAtStart else { return }
      if let address = start.authorizationUrl, let url = URL(string: address) {
        let callback = try await session.authenticate(
          using: url, callbackURLScheme: Self.oauthCallbackScheme)
        let result = try oauthResult(from: callback)
        guard generation == generationAtStart else { return }
        let saved = try await client.finishMCPSignIn(
          id, code: result.code, state: result.state, iss: result.iss)
        guard generation == generationAtStart else { return }
        if let index = mcpServers.firstIndex(where: { $0.id == id }) { mcpServers[index] = saved }
      } else if start.authorized == true, let index = mcpServers.firstIndex(where: { $0.id == id }) {
        mcpServers[index].authenticated = true
      }
      showNotice("Signed in")
    } catch ASWebAuthenticationSessionError.canceledLogin {
      return
    } catch {
      guard generation == generationAtStart else { return }
      errorText = friendlyError(error)
    }
  }

  private func finishMCPSignIn(_ id: String, generation: Int) {
    if self.generation == generation, signingIn == id { signingIn = nil }
  }

  func signOutOfMCP(_ id: String) {
    guard let old = mcpServers.first(where: { $0.id == id }),
      let index = mcpServers.firstIndex(where: { $0.id == id })
    else { return }
    var signedOut = old
    signedOut.authenticated = false
    signedOut.auth = "none"
    optimisticMutation(
      key: "mcp:\(id)", update: { [self] in mcpServers[index] = signedOut },
      rollback: { [self] in
        if let current = mcpServers.firstIndex(where: { $0.id == id }) { mcpServers[current] = old }
      },
      work: { client in
        let saved = try await client.signOutOfMCP(id)
        return { [self] in
          if let current = mcpServers.firstIndex(where: { $0.id == id }) {
            mcpServers[current] = saved
          }
        }
      })
  }

  func deleteMCP(_ id: String) {
    guard let old = mcpServers.first(where: { $0.id == id }),
      let index = mcpServers.firstIndex(where: { $0.id == id })
    else { return }
    let affectedAgents = agents.compactMap { agent -> (String, [String])? in
      guard agent.mcpServers?.contains(id) == true else { return nil }
      return (agent.id, agent.mcpServers ?? [])
    }
    optimisticMutation(
      key: "mcp:\(id)",
      update: { [self] in
        mcpServers.removeAll { $0.id == id }
        for (agentID, _) in affectedAgents {
          if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].mcpServers?.removeAll { $0 == id }
          }
        }
      },
      rollback: { [self] in
        mcpServers.insert(old, at: min(index, mcpServers.count))
        for (agentID, memberships) in affectedAgents {
          if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].mcpServers = memberships
          }
        }
      },
      work: { client in
        try await client.deleteMCPServer(id)
        return nil
      })
  }

  /// Servers a bot may use: the shared ones and its own.
  func usableServers(for agentID: String) -> [MCPServer] {
    mcpServers.filter { $0.agentId == nil || $0.agentId == agentID }
  }
}
