import apfelkern
import AuthenticationServices
import SwiftUI

struct MemoryPanel: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var scope = "all"

    var body: some View {
        Form {
            Section {
                Picker("Scope", selection: $scope) {
                    Text("All").tag("all")
                    Text("Shared").tag("shared")
                    ForEach(model.agents) { agent in Text(agent.name).tag(agent.id) }
                }
                .pickerStyle(.menu)
            }
            sharedSection
            personalSections
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: "Search memories")
    }

    @ViewBuilder private var sharedSection: some View {
        if scope == "all" || scope == "shared" {
            Section {
                let memories = filtered(model.sharedMemories)
                if memories.isEmpty {
                    Text(query.isEmpty ? "No shared memories yet." : "No shared memories match your search.")
                        .foregroundStyle(.secondary)
                }
                ForEach(memories) { memory in
                    row(memory, agentID: nil)
                }
            } header: {
                Text("Shared · \(model.sharedMemories.count)")
            } footer: {
                Text(sharedFooter).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var personalSections: some View {
        if scope != "shared" {
            ForEach(model.agents.filter { scope == "all" || $0.id == scope }) { agent in
                Section {
                    let memories = filtered(model.agentMemories[agent.id] ?? [])
                    if memories.isEmpty {
                        Text(query.isEmpty ? "No memories yet." : "No memories match your search.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(memories) { memory in
                        row(memory, agentID: agent.id)
                    }
                } header: {
                    Text("\(agent.name) · \(model.agentMemories[agent.id, default: []].count)")
                }
            }
        }
    }

    private func filtered(_ memories: [Memory]) -> [Memory] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(query) }
    }

    private var sharedFooter: String {
        let enabled = model.agents.filter { $0.sharedMemory == true }.map(\.name)
        return enabled.isEmpty
            ? "No bots use shared memory. Turn it on in a bot's profile."
            : "Used by: " + enabled.joined(separator: ", ")
    }

    private func row(_ memory: Memory, agentID: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.content)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let source = memorySourceLabel(memory.source) {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                rowActions(memory, agentID: agentID)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("More")
        }
        .contextMenu { rowActions(memory, agentID: agentID) }
        .disabled(memory.id.hasPrefix("pending-"))
    }

    @ViewBuilder private func rowActions(_ memory: Memory, agentID: String?) -> some View {
        Button("Edit…") { model.openMemoryForm(memory.id, agentID: agentID) }
        Button("Delete", role: .destructive) { model.deleteMemory(memory.id, agentID: agentID) }
    }
}

/// Where a memory was saved, for the line under it; nil for memories saved before sources were recorded.
func memorySourceLabel(_ source: MemorySource?) -> String? {
    guard let source else { return nil }
    let name = source.name?.nilIfEmpty
    switch source.kind {
    case "chat": return "From the bot chat"
    case "owner": return "Added by you"
    case "task": return name.map { "From the task \($0)" } ?? "From a scheduled task"
    case "bot": return name.map { "From a request by \($0)" } ?? "From another bot"
    case "group": return name.map { "From the group chat \($0)" } ?? "From a group chat"
    default: return nil
    }
}
