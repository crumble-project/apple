import AuthenticationServices
import SwiftUI

struct IntegrationsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Form {
            Section {
                let shared = model.mcpServers.filter { $0.agentId == nil }
                if shared.isEmpty {
                    Text("No shared MCP servers yet.").foregroundStyle(.secondary)
                }
                ForEach(shared) { server in
                    row(server)
                }
                Button("Add Shared MCP Server", systemImage: "plus") { model.openMCPForm("", agentID: nil) }
            } header: {
                Text("Shared")
            } footer: {
                Text("Every bot can use these. Turn one on for a bot in its profile.").foregroundStyle(.secondary)
            }
            ForEach(model.agents) { agent in
                Section {
                    let own = model.mcpServers.filter { $0.agentId == agent.id }
                    if own.isEmpty {
                        Text("No MCP servers of its own.").foregroundStyle(.secondary)
                    }
                    ForEach(own) { server in
                        row(server)
                    }
                    Button("Add MCP Server", systemImage: "plus") { model.openMCPForm("", agentID: agent.id) }
                } header: {
                    Text(agent.name)
                } footer: {
                    Text("Only \(agent.name) can use these, with their own sign-in.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ server: MCPServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).fontWeight(.semibold)
                Text(server.url).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(signInStatus(server)).font(.caption).foregroundStyle(.secondary)
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

    private func signInStatus(_ server: MCPServer) -> String {
        switch server.auth {
        case "oauth": "Signed in with OAuth"
        case "token": "Uses a token"
        default: "No sign-in"
        }
    }
}

/// The Cancel and Save buttons of a form sheet.
