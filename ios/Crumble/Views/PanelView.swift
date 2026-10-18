import AuthenticationServices
import SwiftUI

/// The workspace pages: memory, skills, tasks, activity, and integrations.
struct PanelView: View {
  @Environment(AppModel.self) private var model
  let panel: Route

  var body: some View {
    content
      .navigationTitle(panel.title)
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          switch panel {
          case .memory:
            Button("New Memory", systemImage: "plus") {
              model.openMemoryForm("", agentID: nil)
            }
          case .skills:
            Button("New Shared Skill", systemImage: "plus") { model.openSkillForm("") }
          case .tasks:
            Button("New Task", systemImage: "plus") { model.openTaskForm("") }.disabled(
              model.agents.isEmpty)
          case .integrations:
            Button("Add Shared MCP Server", systemImage: "plus") {
              model.openMCPForm("", agentID: nil)
            }
          default:
            EmptyView()
          }
          Button("Refresh", systemImage: "arrow.clockwise") { model.openPanel(panel) }
        }
      }
  }

  @ViewBuilder private var content: some View {
    switch panel {
    case .memory: MemoryPanel()
    case .skills: SkillsPanel()
    case .tasks: TasksPanel()
    case .activity: ActivityPanel()
    case .integrations: IntegrationsPanel()
    case .agent: EmptyView()
    }
  }
}

private struct MemoryPanel: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var scope: MemoryScope = .all
  @State private var pendingDelete: MemoryDeletion?
  @State private var collapsedSections: Set<String> = []

  private enum MemoryScope: Hashable, Identifiable {
    case all, shared, bot(String)
    var id: String {
      switch self { case .all: "all"; case .shared: "shared"; case .bot(let id): "bot:" + id }
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
          description: Text(query.isEmpty ? "Add a shared memory or one for a specific bot." : "Try a different search or scope."))
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
      if scope != .shared {
        ForEach(model.agents.filter { agent in
          switch scope { case .all: return !(visiblePersonal[agent.id] ?? []).isEmpty; case .bot(let id): return id == agent.id; case .shared: return false }
        }) { agent in
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
    .formStyle(.grouped)
    .searchable(text: $query, placement: .automatic, prompt: "Search memories")
    .confirmationDialog("Delete this memory?", item: $pendingDelete) { item in
      Button("Delete", role: .destructive) { model.deleteMemory(item.id, agentID: item.agentID) }
      Button("Cancel", role: .cancel) {}
    } message: { item in Text(item.label) }
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

private struct SkillsPanel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        if model.sharedSkills.isEmpty {
          Text("No shared skills yet.").foregroundStyle(.secondary)
        }
        ForEach(model.sharedSkills) { skill in
          DisclosureGroup {
            Text(skill.instructions)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            if let path = skill.path, !path.isEmpty {
              Text("Source: \(path)").font(.caption).foregroundStyle(.secondary)
            }
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).fontWeight(.semibold)
                if skill.isDefault {
                  Text("Default · Every bot").font(.caption).foregroundStyle(.secondary)
                } else {
                  let enabled = model.agents.filter { $0.sharedSkills?.contains(skill.id) == true }
                    .map(\.name)
                  Text(
                    enabled.isEmpty
                      ? "No bots enabled" : "Enabled for: " + enabled.joined(separator: ", ")
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if !skill.isDefault {
                Menu {
                  Section("Enable for bot") {
                    ForEach(model.agents) { agent in
                      Button {
                        model.setSharedSkill(
                          skill.id, for: agent.id,
                          enabled: !(agent.sharedSkills?.contains(skill.id) ?? false))
                      } label: {
                        Label(
                          agent.name,
                          systemImage: agent.sharedSkills?.contains(skill.id) == true
                            ? "checkmark.circle.fill" : "circle")
                      }
                      .disabled(model.pendingMutations.contains("agent-skill:\(agent.id):sharedSkills"))
                    }
                  }
                  Button("Edit") { model.openSkillForm(skill.id) }
                  Button("Delete", role: .destructive) { model.deleteSharedSkill(skill.id) }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Skill actions")
                .disabled(skill.id.hasPrefix("pending-") || model.pendingMutations.contains("skill:\(skill.id)"))
              }
            }
          }
        }
      } header: {
        Text("Shared")
      } footer: {
        Text(
          "Defaults apply to every bot. Enable optional shared skills for each bot here. Edit default files on the server and restart it to load changes."
        ).foregroundStyle(.secondary)
      }
      ForEach(model.agents) { agent in
        Section {
          let skills = agent.skills ?? []
          if skills.isEmpty {
            Text("No skills of its own.").foregroundStyle(.secondary)
          }
          ForEach(skills) { skill in
            DisclosureGroup {
              Text(skill.instructions)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
              HStack {
                Text(skill.name).fontWeight(.semibold)
                Spacer()
                Menu {
                  Button("Edit") { model.openPersonalSkillForm(agentID: agent.id, skillID: skill.id.uuidString) }
                  Button("Delete", role: .destructive) { model.deletePersonalSkill(skill.id.uuidString, from: agent.id) }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Skill actions")
                .disabled(model.pendingMutations.contains("agent-skill:\(agent.id):skills"))
              }
            }
          }
          Button("New Skill", systemImage: "plus") {
            model.openPersonalSkillForm(agentID: agent.id)
          }.disabled(model.pendingMutations.contains("agent-skill:\(agent.id):skills"))
        } header: {
          Text(agent.name)
        } footer: {
          Text("Instructions only \(agent.name) follows.").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct TasksPanel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if model.agents.isEmpty {
      ContentUnavailableView(
        "No Tasks", systemImage: "calendar.badge.clock",
        description: Text("Create an agent, then give it a task to run once or on a schedule."))
    } else {
      Form {
        ForEach(model.agents) { agent in
          let tasks = model.schedules.filter { $0.agentId == agent.id }
          Section {
            if tasks.isEmpty {
              Text("No tasks yet.").foregroundStyle(.secondary)
            }
            ForEach(tasks) { schedule in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(schedule.name).fontWeight(.semibold)
                  Text(schedule.prompt).lineLimit(2)
                  Text(timing(schedule)).font(.caption).foregroundStyle(.secondary)
                  if let creator = schedule.createdByAgentId, creator != agent.id,
                    let name = model.agents.first(where: { $0.id == creator })?.name
                  {
                    Text("Scheduled by \(name)").font(.caption).foregroundStyle(.secondary)
                  }
                }
                Spacer()
                Menu {
                  Button("Run Now") { model.runSchedule(schedule.id) }
                    .disabled(!schedule.enabled)
                  Button("Edit") { model.openTaskForm(schedule.id) }
                  Button("Delete", role: .destructive) { model.deleteSchedule(schedule.id) }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Task actions")
                .disabled(schedule.id.hasPrefix("pending-"))
              }
            }
            Button("New Task", systemImage: "plus") { model.openTaskForm("", agentID: agent.id) }
          } header: {
            Text(agent.name)
          } footer: {
            Text("Runs in \(agent.name)’s chat, once or on a schedule.").foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
    }
  }

  private func timing(_ schedule: Schedule) -> String {
    var timing = schedule.runAt ?? ""
    if let cron = schedule.cron, !cron.isEmpty { timing = cron + " · " + (schedule.timezone ?? "") }
    return schedule.enabled ? timing : "Paused · " + timing
  }
}

private struct ActivityPanel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if model.activities.isEmpty {
      ContentUnavailableView(
        "No Activity", systemImage: "waveform.path.ecg",
        description: Text("Tool calls and bot messages will appear here."))
    } else {
      Form {
        Section {
          ForEach(model.activities) { activity in
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                  Text(activity.kind.replacingOccurrences(of: "-", with: " ").capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                  Text(activityTime(activity.timestamp)).font(.caption).foregroundStyle(.secondary)
                }
                Text(activity.agentName).font(.headline)
                Text(activitySummary(activity)).lineLimit(2)
                DisclosureGroup("Details") { Text(activity.details.prettyPrinted).font(.caption.monospaced()).textSelection(.enabled) }
              }
              Spacer()
              Button("Open Chat") { model.selectAgent(activity.agentId) }
            }
          }
        }
      }
      .formStyle(.grouped)
    }
  }

  private func activitySummary(_ activity: ActivityRecord) -> String {
    let details = activity.details
    if let tool = details["toolName"]?.stringValue ?? details["name"]?.stringValue {
      if let status = details["status"]?.stringValue { return "\(tool) · \(status)" }
      return tool
    }
    if let from = details["from"]?.stringValue, let to = details["to"]?.stringValue {
      return "\(from) → \(to)"
    }
    return details["content"]?.stringValue ?? activity.kind.replacingOccurrences(of: "-", with: " ").capitalized
  }
}

private struct IntegrationsPanel: View {
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
        Text("Every bot can use these. Turn one on for a bot in its profile.").foregroundStyle(
          .secondary)
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
          Text("Only \(agent.name) can use these, with their own sign-in.").foregroundStyle(
            .secondary)
        }
      }
    }
    .formStyle(.grouped)
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
          Button("Delete", role: .destructive) { model.deleteMCP(server.id) }
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

/// The Cancel and Save buttons of a form sheet.
private struct SheetActions: ToolbarContent {
  let onCancel: () -> Void
  let onSave: () -> Void
  let saveDisabled: Bool

  var body: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
    ToolbarItem(placement: .confirmationAction) {
      Button("Save", action: onSave).disabled(saveDisabled)
    }
  }
}

struct MemoryFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: MemoryDraft

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        if draft.memoryID.isEmpty {
          Picker("Remembered by", selection: $draft.agentID) {
            Text("Shared").tag(String?.none)
            ForEach(model.agents) { agent in
              Text(agent.name).tag(Optional(agent.id))
            }
          }
        }
        Section("Memory Entry") {
          TextEditor(text: $draft.content).frame(minHeight: 120)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Memory")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.memoryDraft = nil
            dismiss()
          }, onSave: model.saveMemory, saveDisabled: model.loading)
      }
    }
  }
}

struct TaskFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: TaskDraft

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        Section("Task") {
          Picker("Runs on", selection: $draft.agentID) {
            ForEach(model.agents) { agent in
              Text(agent.name).tag(agent.id)
            }
          }
          TextField("Task name", text: $draft.name, prompt: Text("Task name"))
            .accessibilityLabel("Task name")
          Toggle("Enabled", isOn: $draft.enabled)
        }
        Section("Prompt") {
          TextEditor(text: $draft.prompt).frame(minHeight: 80)
        }
        Section {
          Picker("Frequency", selection: $draft.repeats) {
            Text("Run once").tag(false)
            Text("Repeat").tag(true)
          }
          if draft.repeats {
            TextField("Cron expression", text: $draft.cron, prompt: Text("0 9 * * 1-5"))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          } else {
            DatePicker("Date", selection: $draft.runDate, displayedComponents: .date)
            DatePicker("Time", selection: $draft.runDate, displayedComponents: .hourAndMinute)
              .datePickerStyle(.compact)
          }
          TextField("Time zone", text: $draft.timezone, prompt: Text("UTC"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Schedule")
        } footer: {
          Text(
            draft.repeats
              ? "The cron expression runs in the selected time zone."
              : "Date and time are shown in the selected time zone."
          ).foregroundStyle(.secondary)
        }
        .environment(\.timeZone, TimeZone(identifier: draft.timezone) ?? .current)
      }
      .formStyle(.grouped)
      .navigationTitle("Task")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.taskDraft = nil
            dismiss()
          }, onSave: model.saveTask, saveDisabled: model.loading)
      }
    }
  }
}

struct MCPFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: MCPDraft

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        Section {
          if draft.serverID.isEmpty {
            Picker("Available to", selection: $draft.agentID) {
              Text("Every bot (shared)").tag(String?.none)
              ForEach(model.agents) { agent in
                Text(agent.name).tag(Optional(agent.id))
              }
            }
          }
          TextField("Server name", text: $draft.name, prompt: Text("Server name"))
            .accessibilityLabel("MCP server name")
          TextField("HTTP URL", text: $draft.url, prompt: Text("https://"))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Token", text: $draft.token, prompt: Text("Token (optional)"))
          Toggle("Enabled", isOn: $draft.enabled)
        } header: {
          Text("MCP Server")
        } footer: {
          Text(
            "Leave the token empty for servers that use OAuth, then choose Sign In in the list after saving."
          )
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("MCP Server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.mcpDraft = nil
            dismiss()
          }, onSave: model.saveMCP, saveDisabled: model.loading)
      }
    }
  }
}

struct SkillFormView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: SkillDraft

  var body: some View {
    NavigationStack {
      Form {
        SheetError()
        Section {
          TextField("Skill name", text: $draft.name, prompt: Text("Skill name"))
            .accessibilityLabel("Shared skill name")
          TextEditor(text: $draft.instructions).frame(minHeight: 120)
        } header: {
          Text(draft.agentID == nil ? "Shared Skill" : "Bot Skill")
        } footer: {
          Text(
            draft.agentID == nil
              ? "Enable this shared skill for bots from the Skills workspace."
              : "This skill belongs to the selected bot and runs in its chat."
          )
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Shared Skill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetActions(
          onCancel: {
            model.errorText = ""
            model.skillDraft = nil
            dismiss()
          }, onSave: model.saveSkill, saveDisabled: model.loading)
      }
    }
  }
}
