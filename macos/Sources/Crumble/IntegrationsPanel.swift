import apfelkern
import AuthenticationServices
import SwiftUI

struct IntegrationsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Form {
            Section {
                if model.mcpServers.isEmpty {
                    Text("No MCP servers yet.").foregroundStyle(.secondary)
                }
                ForEach(model.mcpServers.filter { $0.agentId == nil }) { server in
                    row(server)
                }
                ForEach(model.agents) { agent in
                    ForEach(model.mcpServers.filter { $0.agentId == agent.id }) { server in
                        row(server)
                    }
                }
                Button("Add MCP Server", systemImage: "plus") { model.openMCPForm("", agentID: nil) }
            } footer: {
                Text("""
                    Turn a server on for a bot in its profile. A server for one bot has its own sign-in, so two bots \
                    can use the same service with different accounts.
                    """).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ server: MCPServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).fontWeight(.semibold)
                Text(server.url).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(scope(server) + " · " + signInStatus(server)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !server.enabled {
                Text("Disabled").font(.caption).foregroundStyle(.secondary)
            }
            if model.signingIn == server.id {
                ProgressView().controlSize(.small)
            } else if server.auth == "oauth" {
                Button("Sign Out") { model.signOutOfMCP(server.id) }
            } else {
                Button("Sign In…") {
                    Task { await model.signInToMCP(server.id, using: webAuthenticationSession) }
                }
                .disabled(model.signingIn != nil)
                .help("Sign in to a server that uses OAuth")
            }
            Button("Edit") { model.openMCPForm(server.id) }.disabled(server.id.hasPrefix("pending-"))
            Button("Delete") { model.deleteMCP(server.id) }.disabled(server.id.hasPrefix("pending-"))
        }
    }

    private func scope(_ server: MCPServer) -> String {
        guard let agentID = server.agentId else { return "Shared" }
        return "Only " + (model.agents.first { $0.id == agentID }?.name ?? "one bot")
    }

    private func signInStatus(_ server: MCPServer) -> String {
        switch server.auth {
        case "oauth": "Signed in with OAuth"
        case "token": "Uses a token"
        default: "No sign-in"
        }
    }
}

/// The Cancel and Save buttons of a form sheet.
