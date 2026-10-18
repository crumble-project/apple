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
                        Button("New Shared Memory", systemImage: "plus") { model.openMemoryForm("", agentID: nil) }
                    case .skills:
                        Button("New Shared Skill", systemImage: "plus") { model.openSkillForm("") }
                    case .tasks:
                        Button("New Task", systemImage: "plus") { model.openTaskForm("") }.disabled(model.agents.isEmpty)
                    case .integrations:
                        Button("Add Shared MCP Server", systemImage: "plus") { model.openMCPForm("", agentID: nil) }
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

    var body: some View {
        Form {
            Section {
                if model.sharedMemories.isEmpty {
                    Text("No shared memories yet.").foregroundStyle(.secondary)
                }
                ForEach(model.sharedMemories) { memory in
                    row(memory, agentID: nil)
                }
                Button("New Shared Memory", systemImage: "plus") { model.openMemoryForm("", agentID: nil) }
            } header: {
                Text("Shared")
            } footer: {
                Text(sharedFooter).foregroundStyle(.secondary)
            }
            ForEach(model.agents) { agent in
                let memories = model.agentMemories[agent.id] ?? []
                Section {
                    if memories.isEmpty {
                        Text("No memories yet.").foregroundStyle(.secondary)
                    }
                    ForEach(memories) { memory in
                        row(memory, agentID: agent.id)
                    }
                    Text("\(memories.count) personal memor\(memories.count == 1 ? "y" : "ies")")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("New Memory", systemImage: "plus") { model.openMemoryForm("", agentID: agent.id) }
                } header: {
                    Text(agent.name)
                } footer: {
                    Text("What \(agent.name) remembers between chats.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sharedFooter: String {
        let enabled = model.agents.filter { $0.sharedMemory == true }.map(\.name)
        return enabled.isEmpty ? "No bots use shared memory. Turn it on in a bot's profile." : "Used by: " + enabled.joined(separator: ", ")
    }

    private func row(_ memory: Memory, agentID: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(memory.content).textSelection(.enabled)
            Spacer()
            Button("Edit") { model.openMemoryForm(memory.id, agentID: agentID) }.disabled(memory.id.hasPrefix("pending-"))
            Button("Delete") { model.deleteMemory(memory.id, agentID: agentID) }.disabled(memory.id.hasPrefix("pending-"))
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
                                    let enabled = model.agents.filter { $0.sharedSkills?.contains(skill.id) == true }.map(\.name)
                                    Text(enabled.isEmpty ? "No bots enabled" : "Enabled for: " + enabled.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !skill.isDefault {
                                Button("Edit") { model.openSkillForm(skill.id) }.disabled(skill.id.hasPrefix("pending-"))
                                Button("Delete") { model.deleteSharedSkill(skill.id) }.disabled(skill.id.hasPrefix("pending-"))
                            }
                        }
                    }
                }
            } header: {
                Text("Shared")
            } footer: {
                Text("Defaults apply to every bot. Enable optional shared skills in a bot’s profile. Edit default files on the server and restart it to load changes.").foregroundStyle(.secondary)
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
                            Text(skill.name).fontWeight(.semibold)
                        }
                    }
                    Button("Edit in Profile…") { model.openEditor(agentID: agent.id) }
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
            ContentUnavailableView("No Tasks", systemImage: "calendar.badge.clock", description: Text("Create an agent, then give it a task to run once or on a schedule."))
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
                                       let name = model.agents.first(where: { $0.id == creator })?.name {
                                        Text("Scheduled by \(name)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Run Now") { model.runSchedule(schedule.id) }.disabled(!schedule.enabled || schedule.id.hasPrefix("pending-"))
                                Button("Edit") { model.openTaskForm(schedule.id) }.disabled(schedule.id.hasPrefix("pending-"))
                                Button("Delete") { model.deleteSchedule(schedule.id) }.disabled(schedule.id.hasPrefix("pending-"))
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
        if model.executions.isEmpty {
            ContentUnavailableView("No Activity", systemImage: "waveform.path.ecg", description: Text("Work from chats and tasks will appear here."))
        } else {
            Form {
                Section {
                    ForEach(model.executions) { execution in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(execution.status ?? "")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: .capsule)
                                    Text(activityTime(execution.createdAt)).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(execution.prompt ?? "").lineLimit(2)
                                if let error = execution.error, !error.isEmpty {
                                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                                }
                            }
                            Spacer()
                            if let agent = execution.agentId, !agent.isEmpty {
                                Button("Open Chat") { model.selectAgent(agent) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
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
private struct SheetActions: ToolbarContent {
    let onCancel: () -> Void
    let onSave: () -> Void
    let saveDisabled: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        ToolbarItem(placement: .confirmationAction) { Button("Save", action: onSave).disabled(saveDisabled) }
    }
}

struct MemoryFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: MemoryDraft

    var body: some View {
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
        .frame(width: 460)
        .toolbar {
            SheetActions(onCancel: { model.errorText = ""; model.memoryDraft = nil }, onSave: model.saveMemory, saveDisabled: model.loading)
        }
    }
}

struct TaskFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: TaskDraft

    var body: some View {
        Form {
            SheetError()
            Section("Task") {
                Picker("Runs on", selection: $draft.agentID) {
                    ForEach(model.agents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                TextField("Name", text: $draft.name, prompt: Text("Required"))
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
                } else {
                    DatePicker("Date", selection: $draft.runDate, displayedComponents: .date)
                    DatePicker("Time", selection: $draft.runDate, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField)
                }
                TextField("Time zone", text: $draft.timezone, prompt: Text("UTC"))
            } header: {
                Text("Schedule")
            } footer: {
                Text(draft.repeats ? "The cron expression runs in the selected time zone." : "Date and time are shown in the selected time zone.").foregroundStyle(.secondary)
            }
            .environment(\.timeZone, TimeZone(identifier: draft.timezone) ?? .current)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            SheetActions(onCancel: { model.errorText = ""; model.taskDraft = nil }, onSave: model.saveTask, saveDisabled: model.loading)
        }
    }
}

struct MCPFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: MCPDraft

    var body: some View {
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
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextField("HTTP URL", text: $draft.url, prompt: Text("https://"))
                SecureField("Token", text: $draft.token, prompt: Text("Optional"))
                Toggle("Enabled", isOn: $draft.enabled)
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Leave the token empty for servers that use OAuth, then choose Sign In in the list after saving.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            SheetActions(onCancel: { model.errorText = ""; model.mcpDraft = nil }, onSave: model.saveMCP, saveDisabled: model.loading)
        }
    }
}

struct SkillFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: SkillDraft

    var body: some View {
        Form {
            SheetError()
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextEditor(text: $draft.instructions).frame(minHeight: 120)
            } header: {
                Text("Shared Skill")
            } footer: {
                Text("Bots that turn this skill on in their profile follow these instructions.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            SheetActions(onCancel: { model.errorText = ""; model.skillDraft = nil }, onSave: model.saveSkill, saveDisabled: model.loading)
        }
    }
}
