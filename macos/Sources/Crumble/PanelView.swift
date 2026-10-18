import AuthenticationServices
import SwiftUI

/// The workspace pages: memory, tasks, activity, approvals, and integrations.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    let panel: Route

    var body: some View {
        content
            .navigationTitle(panel.title)
            .navigationSubtitle(panel == .memory ? model.selectedAgent?.name ?? "" : "")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    switch panel {
                    case .memory where model.selectedAgent != nil:
                        Button("New Memory", systemImage: "plus") { model.openMemoryForm("") }
                    case .tasks:
                        Button("New Task", systemImage: "plus") { model.openTaskForm("") }.disabled(model.selectedAgent == nil)
                    case .integrations:
                        Button("Add MCP Server", systemImage: "plus") { model.openMCPForm("") }
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
        case .tasks: TasksPanel()
        case .activity: ActivityPanel()
        case .approvals: ApprovalsPanel()
        case .integrations: IntegrationsPanel()
        case .agent: EmptyView()
        }
    }
}

private struct MemoryPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let agent = model.selectedAgent {
            if model.memories.isEmpty {
                ContentUnavailableView("No Memories Yet", systemImage: "brain", description: Text("What \(agent.name) remembers between chats appears here."))
            } else {
                Form {
                    Section {
                        ForEach(model.memories) { memory in
                            HStack(alignment: .firstTextBaseline) {
                                Text(memory.content).textSelection(.enabled)
                                Spacer()
                                Button("Edit") { model.openMemoryForm(memory.id) }
                                Button("Delete") { model.deleteMemory(memory.id) }
                            }
                        }
                    } footer: {
                        Text("What \(agent.name) remembers between chats.").foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            ContentUnavailableView("No Agent Selected", systemImage: "brain", description: Text("Select an agent to see its memory."))
        }
    }
}

private struct TasksPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.schedules.isEmpty {
            ContentUnavailableView("No Tasks", systemImage: "calendar.badge.clock", description: Text("Give an agent a task to run once or on a schedule."))
        } else {
            Form {
                Section {
                    ForEach(model.schedules) { schedule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.name).fontWeight(.semibold)
                                Text(schedule.prompt).lineLimit(2)
                                Text(timing(schedule)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Run Now") { model.runSchedule(schedule.id) }.disabled(!schedule.enabled)
                            Button("Edit") { model.openTaskForm(schedule.id) }
                            Button("Delete") { model.deleteSchedule(schedule.id) }
                        }
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

private struct ApprovalsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.approvals.filter { $0.status == "pending" }
        if pending.isEmpty {
            ContentUnavailableView("No Approvals", systemImage: "checkmark.shield", description: Text("No actions need your approval."))
        } else {
            Form {
                ForEach(pending) { approval in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(approval.toolName).fontWeight(.semibold)
                            Text(approval.arguments?.prettyPrinted ?? "")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                Button("Approve Once") { model.decideApproval(approval.id, decision: "approved") }
                                    .buttonStyle(.borderedProminent)
                                Button("Deny") { model.decideApproval(approval.id, decision: "denied") }
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
        if model.mcpServers.isEmpty {
            ContentUnavailableView("No MCP Servers", systemImage: "powerplug",
                                   description: Text("Connect an MCP server, then enable it for individual agents in their profiles."))
        } else {
            Form {
                Section {
                    ForEach(model.mcpServers) { server in
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
                            Button("Edit") { model.openMCPForm(server.id) }
                            Button("Delete") { model.deleteMCP(server.id) }
                        }
                    }
                } footer: {
                    Text("Connect an MCP server, then enable it for individual agents in their profiles.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
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
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                Toggle("Enabled", isOn: $draft.enabled)
            }
            Section("Prompt") {
                TextEditor(text: $draft.prompt).frame(minHeight: 80)
            }
            Section {
                TextField("Repeat", text: $draft.cron, prompt: Text("0 9 * * 1-5"))
                TextField("Run once at", text: $draft.runAt, prompt: Text("2026-10-18T09:00:00Z"))
                TextField("Time zone", text: $draft.timezone, prompt: Text("UTC"))
            } header: {
                Text("Schedule")
            } footer: {
                Text("Use a cron expression to repeat, or a date and time to run once.").foregroundStyle(.secondary)
            }
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
