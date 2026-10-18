import apfelkern
import SwiftUI

struct MemoryPanel: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var scope: MemoryScope = .all
  @State private var pendingDelete: MemoryDeletion?
  @State private var collapsedSections: Set<String> = []

  private enum MemoryScope: Hashable, Identifiable {
    case all, shared, bot(String)
    var id: String {
      switch self {
      case .all: "all"
      case .shared: "shared"
      case .bot(let id): "bot:" + id
      }
    }
  }
  private struct MemoryDeletion: Identifiable {
    let id: String
    let agentID: String?
    let label: String
  }

  var body: some View {
    Form {
      Section {
        Picker("Scope", selection: $scope) {
          Text("All").tag(MemoryScope.all)
          Text("Shared").tag(MemoryScope.shared)
          ForEach(model.agents) { agent in Text(agent.name).tag(MemoryScope.bot(agent.id)) }
        }
        .pickerStyle(.menu)
      } footer: { Text("Search by what was remembered or by bot name.").foregroundStyle(.secondary) }

      if !hasVisibleMemories {
        ContentUnavailableView(
          query.isEmpty ? "No memories yet" : "No matching memories",
          systemImage: query.isEmpty ? "brain" : "magnifyingglass",
          description: Text(
            query.isEmpty ? "Add a shared memory or one for a specific bot." : "Try a different search or scope."))
      }
      if scope == .all || scope == .shared {
        Section {
          DisclosureGroup(isExpanded: sectionBinding("shared")) {
            ForEach(visibleShared) { row($0, agentID: nil) }
          } label: {
            sectionLabel("Shared", count: model.sharedMemories.count)
          }
        } footer: { Text(sharedFooter).foregroundStyle(.secondary) }
      }
      personalSections
    }
    .formStyle(.grouped)
    .searchable(text: $query, placement: .automatic, prompt: "Search memories")
    .confirmationDialog("Delete this memory?", item: $pendingDelete) { item in
      Button("Delete", role: .destructive) { model.deleteMemory(item.id, agentID: item.agentID) }
      Button("Cancel", role: .cancel) {}
    } message: { item in Text(item.label) }
  }

  private var visibleAgents: [Agent] {
    model.agents.filter { agent in
      switch scope {
      case .all: return !(visiblePersonal[agent.id] ?? []).isEmpty
      case .bot(let id): return id == agent.id
      case .shared: return false
      }
    }
  }

  @ViewBuilder private var personalSections: some View {
    if scope != .shared {
      ForEach(visibleAgents) { agent in
        let memories = visiblePersonal[agent.id] ?? []
        Section {
          DisclosureGroup(isExpanded: sectionBinding(agent.id)) {
            if memories.isEmpty { Text("No matching memories.").foregroundStyle(.secondary) }
            ForEach(memories) { row($0, agentID: agent.id) }
          } label: {
            sectionLabel(agent.name, count: model.agentMemories[agent.id, default: []].count)
          }
        }
      }
    }
  }

  private var visibleShared: [Memory] {
    model.sharedMemories.filter { matches($0, owner: "Shared") }
  }
  private var hasVisibleMemories: Bool {
    switch scope {
    case .shared: return !visibleShared.isEmpty
    case .all: return !visibleShared.isEmpty || visiblePersonal.values.contains { !$0.isEmpty }
    case .bot(let id): return !(visiblePersonal[id] ?? []).isEmpty
    }
  }
  private var visiblePersonal: [String: [Memory]] {
    Dictionary(uniqueKeysWithValues: model.agents.map { agent in
      (agent.id, (model.agentMemories[agent.id] ?? []).filter { matches($0, owner: agent.name) })
    })
  }
  private func matches(_ memory: Memory, owner: String) -> Bool {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return search.isEmpty || memory.content.localizedCaseInsensitiveContains(search)
      || owner.localizedCaseInsensitiveContains(search)
  }

  private func sectionBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !collapsedSections.contains(id) },
      set: { isExpanded in
        if isExpanded {
          collapsedSections.remove(id)
        } else {
          collapsedSections.insert(id)
        }
      }
    )
  }

  private func sectionLabel(_ title: String, count: Int) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text("\(count)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel("\(count) memories")
    }
  }

  private var sharedFooter: String {
    let enabled = model.agents.filter { $0.sharedMemory == true }.map(\.name)
    return enabled.isEmpty
      ? "No bots use shared memory. Turn it on in a bot's profile."
      : "Used by: " + enabled.joined(separator: ", ")
  }

  private func row(_ memory: Memory, agentID: String?) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(memory.content)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        Button("Edit") { model.openMemoryForm(memory.id, agentID: agentID) }
        Button("Delete", role: .destructive) {
          pendingDelete = MemoryDeletion(id: memory.id, agentID: agentID, label: memory.content)
        }
      } label: { Image(systemName: "ellipsis.circle") }
      .accessibilityLabel("Memory actions")
      .disabled(memory.id.hasPrefix("pending-"))
    }
  }
}
