import SwiftUI

struct TasksPanel: View {
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
              taskRow(schedule, agent: agent)
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

  private func taskRow(_ schedule: Schedule, agent: Agent) -> some View {
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

  private func timing(_ schedule: Schedule) -> String {
    var timing = schedule.runAt ?? ""
    if let cron = schedule.cron, !cron.isEmpty { timing = cron + " · " + (schedule.timezone ?? "") }
    return schedule.enabled ? timing : "Paused · " + timing
  }
}
