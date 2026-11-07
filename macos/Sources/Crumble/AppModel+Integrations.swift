import apfelkern
import AuthenticationServices
import Foundation
import SwiftUI

extension AppModel {
    /// Opens a server to edit, or a new one owned by `agentID` (nil for shared).
    func openMCPForm(_ id: String, agentID: String? = nil) {
        mcpDraft = mcpServers.first { $0.id == id }.map(MCPDraft.init(server:))
            ?? MCPDraft(serverID: id, agentID: agentID)
    }

    func saveMCP() {
        guard let form = mcpDraft else { return }
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let rawURL = form.url.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let url = URL(string: rawURL), url.host() != nil,
            ["http", "https"].contains(url.scheme ?? "")
        else {
            errorText = "MCP name and an HTTP(S) URL are required."
            return
        }
        let payload = form.payload(name: name, url: rawURL)
        if form.checksPasswordManager {
            saveMCPAfterCheck(form, payload: payload)
            return
        }
        let isNew = form.serverID.isEmpty
        let provisionalID = isNew ? "pending-mcp-" + newRequestID() : form.serverID
        let old = mcpServers.first { $0.id == form.serverID }
        var provisional = MCPServer(
            id: provisionalID, name: name, url: rawURL, enabled: form.enabled, agentId: form.agentID,
            authenticated: false, auth: form.changesToken ? "token" : "none",
            token: old?.token ?? SecretStatus(configured: false),
            oauthClientSecret: old?.oauthClientSecret ?? SecretStatus(configured: false))
        if let old, !form.changesToken, old.url == rawURL {
            provisional.authenticated = old.authenticated
            provisional.auth = old.auth
        }
        persistMCP(form, provisional: form.applyingOAuthApp(to: provisional), payload: payload)
    }

    /// A new reference's outcome is the password manager's: the server reads it before it answers, so
    /// the form holds until then and keeps what the owner entered on failure.
    private func saveMCPAfterCheck(_ form: MCPDraft, payload: [String: JSONValue]) {
        var payload = payload
        let isNew = form.serverID.isEmpty
        let owner = form.agentID
        optimisticMutation(
            key: "mcp:\(form.id)",
            update: { [self] in isCheckingMCP = true },
            rollback: { [self] in isCheckingMCP = false },
            work: { client in
                if isNew, let owner { payload["agentId"] = .string(owner) }
                let saved = try await isNew
                    ? client.createMCPServer(payload) : client.updateMCPServer(form.serverID, patch: payload)
                return { [self] in
                    isCheckingMCP = false
                    if mcpDraft?.id == form.id { mcpDraft = nil }
                    if let index = mcpServers.firstIndex(where: { $0.id == saved.id }) {
                        mcpServers[index] = saved
                    } else {
                        mcpServers.append(saved)
                    }
                    if isNew, let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
                        agents[index].mcpServers = (agents[index].mcpServers ?? []) + [saved.id]
                    }
                }
            })
    }

    private func persistMCP(_ form: MCPDraft, provisional: MCPServer, payload: [String: JSONValue]) {
        let isNew = form.serverID.isEmpty
        let provisionalID = provisional.id
        let old = mcpServers.first { $0.id == form.serverID }
        var payload = payload
        let owner = form.agentID
        mcpDraft = nil
        optimisticMutation(
            key: "mcp:\(provisionalID)",
            update: { [self] in
                if let index = mcpServers.firstIndex(where: { $0.id == provisionalID || $0.id == form.serverID }) {
                    mcpServers[index] = provisional
                } else {
                    mcpServers.append(provisional)
                }
                if isNew, let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
                    var memberships = agents[index].mcpServers ?? []
                    if !memberships.contains(provisionalID) { memberships.append(provisionalID) }
                    agents[index].mcpServers = memberships
                }
            },
            rollback: { [self] in
                mcpServers.removeAll { $0.id == provisionalID }
                if let old { mcpServers.append(old) }
                if isNew, let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
                    agents[index].mcpServers?.removeAll { $0 == provisionalID }
                }
                if workspaceRoute == .integrations, mcpDraft == nil { mcpDraft = form }
            },
            work: { client in
                let saved: MCPServer
                if isNew {
                    if let owner { payload["agentId"] = .string(owner) }
                    saved = try await client.createMCPServer(payload)
                } else {
                    saved = try await client.updateMCPServer(form.serverID, patch: payload)
                }
                return { [self] in
                    reconcileMCP(saved, replacing: provisionalID, owner: isNew ? owner : nil)
                }
            })
    }

    private func reconcileMCP(_ saved: MCPServer, replacing provisionalID: String, owner: String?) {
        if let index = mcpServers.firstIndex(where: { $0.id == provisionalID }) {
            mcpServers[index] = saved
        }
        if let owner, let index = agents.firstIndex(where: { $0.id == owner }) {
            agents[index].mcpServers = (agents[index].mcpServers ?? []).map {
                $0 == provisionalID ? saved.id : $0
            }
        }
    }

    /// Where the system sign-in sheet returns; the sheet watches this scheme, so nothing registers it.
    static let oauthCallbackScheme = AppIdentity.bundleID
    static let oauthRedirectURI = oauthCallbackScheme + ":/oauth/callback"

    /// Signs in to an OAuth MCP server: the server prepares the request, the system sheet shows the
    /// provider's sign-in, and the server exchanges the returned code for tokens it keeps.
    func signInToMCP(_ id: String, using session: WebAuthenticationSession) async {
        guard let client else { return }
        errorText = ""
        signingIn = id
        let generationAtStart = generation
        defer { if generation == generationAtStart, signingIn == id { signingIn = nil } }
        do {
            let start = try await client.startMCPSignIn(id, redirectURI: Self.oauthRedirectURI)
            guard generation == generationAtStart else { return }
            if let address = start.authorizationUrl, let url = URL(string: address) {
                guard try await completeMCPSignIn(
                    id, client: client, session: session, url: url, generationAtStart: generationAtStart
                ) else { return }
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

    private func completeMCPSignIn(
        _ id: String, client: APIClient, session: WebAuthenticationSession, url: URL, generationAtStart: Int
    ) async throws -> Bool {
        let callback = try await session.authenticate(using: url, callbackURLScheme: Self.oauthCallbackScheme)
        let result = try oauthResult(from: callback)
        guard generation == generationAtStart else { return false }
        let saved = try await client.finishMCPSignIn(id, code: result.code, state: result.state, iss: result.iss)
        guard generation == generationAtStart else { return false }
        if let index = mcpServers.firstIndex(where: { $0.id == id }) { mcpServers[index] = saved }
        return true
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
                    if let current = mcpServers.firstIndex(where: { $0.id == id }) { mcpServers[current] = saved }
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
