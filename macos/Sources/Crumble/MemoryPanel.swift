import apfelkern
import AuthenticationServices
import SwiftUI

struct MemoryPanel: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var scope = "all"
    @State private var collapsedSections: Set<String> = []

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
                DisclosureGroup(isExpanded: expansion(for: "shared")) {
                    let memories = filtered(model.sharedMemories)
                    if memories.isEmpty {
                        Text(query.isEmpty ? "No shared memories yet." : "No shared memories match your search.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(memories) { memory in
                        row(memory, agentID: nil)
                    }
                } label: {
                    Text("Shared · \(model.sharedMemories.count)")
                }
            } footer: {
                Text(sharedFooter).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var personalSections: some View {
        if scope != "shared" {
            ForEach(model.agents.filter { scope == "all" || $0.id == scope }) { agent in
                Section {
                    DisclosureGroup(isExpanded: expansion(for: agent.id)) {
                        let memories = filtered(model.agentMemories[agent.id] ?? [])
                        if memories.isEmpty {
                            Text(query.isEmpty ? "No memories yet." : "No memories match your search.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(memories) { memory in
                            row(memory, agentID: agent.id)
                        }
                    } label: {
                        Text("\(agent.name) · \(model.agentMemories[agent.id, default: []].count)")
                    }
                }
            }
        }
    }

    private func expansion(for section: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(section) },
            set: { expanded in
                if expanded { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
            }
        )
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
        HStack(alignment: .top) {
            Text(memory.content)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit") { model.openMemoryForm(memory.id, agentID: agentID) }
                .disabled(memory.id.hasPrefix("pending-"))
            Button("Delete", role: .destructive) { model.deleteMemory(memory.id, agentID: agentID) }
                .tint(.red)
                .disabled(memory.id.hasPrefix("pending-"))
        }
    }
}
