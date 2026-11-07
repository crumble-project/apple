import apfelkern
import AuthenticationServices
import SwiftUI

struct IntegrationsPanel: View {
  @Environment(AppModel.self) private var model
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var query = ""
  @State private var deleting: MCPServer?

  private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private func servers(of agentID: String?) -> [MCPServer] {
    model.mcpServers.filter { $0.agentId == agentID && $0.matches(query) }
  }

  var body: some View {
    Form {
      sharedSection
      ForEach(searching ? model.agents.filter { !servers(of: $0.id).isEmpty } : model.agents) { agent in
        Section {
          let own = servers(of: agent.id)
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
          Text("Only \(agent.name) can use these, with their own sign-in.").foregroundStyle(
            .secondary)
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Delete \(deleting?.name ?? "this server")?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible,
      presenting: deleting
    ) { server in
      Button("Delete", role: .destructive) { model.deleteMCP(server.id) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Bots lose its tools and its sign-in is removed. This cannot be undone.")
    }
    .searchable(text: $query, placement: .automatic, prompt: "Search MCP servers")
  }

  private var sharedSection: some View {
    Section {
      let shared = servers(of: nil)
      if shared.isEmpty {
        Text(searching ? "No shared MCP servers match your search." : "No shared MCP servers yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(shared) { server in
        row(server)
      }
      Button("Add Shared MCP Server", systemImage: "plus") { model.openMCPForm("", agentID: nil) }
    } header: {
      Text("Shared")
    } footer: {
      Text("Every bot can use these. Turn one on for a bot in its profile.").foregroundStyle(
        .secondary)
    }
  }

  private func row(_ server: MCPServer) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name).fontWeight(.semibold)
        Text(server.url).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(
          .middle)
        Text(signInStatus(server)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if !server.enabled {
        Text("Disabled").font(.caption).foregroundStyle(.secondary)
      }
      if model.signingIn == server.id {
        ProgressView()
      } else {
        Menu {
          if server.auth == "oauth" {
            Button("Sign Out") { model.signOutOfMCP(server.id) }
          } else {
            Button("Sign In…") {
              Task { await model.signInToMCP(server.id, using: webAuthenticationSession) }
            }
            .disabled(model.signingIn != nil)
          }
          Button("Edit") { model.openMCPForm(server.id) }
          Button("Delete…", role: .destructive) { deleting = server }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Server actions")
        .disabled(server.id.hasPrefix("pending-"))
      }
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
