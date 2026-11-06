import apfelkern
import SwiftUI

/// The Automations page: the list with its status pills, and the run history.
public struct AutomationsPage: View {
  @Bindable var board: AutomationBoard
  let agents: [Agent]
  let sources: [EventSource]
  let client: APIClient?
  let onCreate: () -> Void
  let onRun: (Schedule) -> Void
  let onOpenBot: (String) -> Void

  @State private var deleting: Schedule?
  @State private var output: AutomationRun?

  public init(
    board: AutomationBoard, agents: [Agent], sources: [EventSource], client: APIClient?,
    onCreate: @escaping () -> Void, onRun: @escaping (Schedule) -> Void, onOpenBot: @escaping (String) -> Void
  ) {
    self.board = board
    self.agents = agents
    self.sources = sources
    self.client = client
    self.onCreate = onCreate
    self.onRun = onRun
    self.onOpenBot = onOpenBot
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("View", selection: $board.view) {
        Text("Automations").tag(AutomationsView.automations)
        Text("Runs").tag(AutomationsView.runs)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal)
      if board.view == .automations {
        FilterPills(label: "Status", pills: pills, selection: $board.filter).padding(.horizontal)
        automations
      } else {
        runs
      }
    }
    .padding(.top, 8)
    .confirmationDialog(
      "Delete \(deleting?.name ?? "")?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
    ) { schedule in
      Button("Delete", role: .destructive) {
        if let client { board.delete(schedule, client: client) }
      }
    } message: { _ in
      Text("The automation stops running. This cannot be undone.")
    }
    .sheet(item: $output) { run in
      if let script = run.script { AutomationRunOutput(title: run.title, run: script) }
    }
  }

  private var pills: [FilterPill<AutomationFilter>] {
    AutomationFilter.allCases.map { FilterPill(value: $0, label: $0.label, count: board.count($0)) }
  }

  private func agent(_ id: String?) -> Agent? { agents.first { $0.id == id } }

  @ViewBuilder private var automations: some View {
    if let error = board.readError, !board.isLoaded {
      failure(error)
    } else if !board.isLoaded {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if board.shown.isEmpty {
      empty
    } else {
      Form {
        ForEach(board.shown) { schedule in
          AutomationRow(
            schedule: schedule, bot: agent(schedule.agentId), creator: creator(of: schedule), sources: sources,
            error: board.errors[schedule.id], isPending: board.isPending(schedule.id),
            isStarting: board.starting.contains(schedule.id), edit: { board.edit(schedule) },
            run: { onRun(schedule) }, toggle: {
              if let client { board.setEnabled(schedule, !schedule.enabled, client: client) }
            }, delete: { deleting = schedule })
        }
      }
      .formStyle(.grouped)
    }
  }

  private func creator(of schedule: Schedule) -> Agent? {
    schedule.createdByAgentId == schedule.agentId ? nil : agent(schedule.createdByAgentId)
  }

  @ViewBuilder private var empty: some View {
    if board.filter == .all {
      ContentUnavailableView {
        Label("No automations yet", systemImage: "calendar.badge.clock")
      } description: {
        Text(
          agents.isEmpty
            ? "Create a bot, then give it an automation to run once or on a schedule."
            : "An automation sends a bot a message once or on a schedule, and the bot answers in its chat.")
      } actions: {
        if !agents.isEmpty { Button("New Automation", action: onCreate) }
      }
    } else {
      ContentUnavailableView(
        "No \(board.filter.label.lowercased()) automations", systemImage: "line.3.horizontal.decrease.circle")
    }
  }

  private func failure(_ text: String) -> some View {
    ContentUnavailableView("Couldn’t Load", systemImage: "exclamationmark.triangle", description: Text(text))
  }

  @ViewBuilder private var runs: some View {
    if let error = board.runsError, !board.runsLoaded {
      failure(error)
    } else if !board.runsLoaded {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if board.runs.isEmpty {
      ContentUnavailableView(
        "No runs yet", systemImage: "clock.arrow.circlepath",
        description: Text("Each time an automation runs, it shows up here."))
    } else {
      Form {
        ForEach(board.runs) { run in
          Button {
            if run.script != nil { output = run } else { onOpenBot(run.agentId) }
          } label: {
            AutomationRunRow(run: run, bot: agent(run.agentId))
          }
          .buttonStyle(.plain)
        }
      }
      .formStyle(.grouped)
    }
  }
}

private struct AutomationRow: View {
  let schedule: Schedule
  let bot: Agent?
  let creator: Agent?
  let sources: [EventSource]
  let error: String?
  let isPending: Bool
  let isStarting: Bool
  let edit: () -> Void
  let run: () -> Void
  let toggle: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: edit) { summary }
        .buttonStyle(.plain)
      Menu {
        Button("Run Now", systemImage: "play", action: run)
          .disabled(!schedule.enabled || isStarting)
        Button("Edit", systemImage: "pencil", action: edit)
        if !schedule.isFinished {
          Button(
            schedule.enabled ? "Pause" : "Resume", systemImage: schedule.enabled ? "pause" : "play.circle",
            action: toggle)
        }
        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .fixedSize()
      .accessibilityLabel("Actions for \(schedule.name)")
    }
    .disabled(isPending)
  }

  private var summary: some View {
    HStack(spacing: 10) {
      if let bot {
        BotAvatarView(agent: bot, size: 28, state: schedule.enabled ? .idle : .sleeping)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(schedule.name).fontWeight(.semibold).lineLimit(1)
          if schedule.kind == .script {
            Text("Script").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
              .overlay(.secondary.opacity(0.5), in: .capsule.stroke())
          }
        }
        Text(owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Text(cadence(schedule, sources: sources)).font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 8) {
          status
          Text("Next run: \(nextRunLabel(schedule))").foregroundStyle(.secondary)
        }
        .font(.caption)
        if let error {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }
      Spacer(minLength: 0)
    }
    .contentShape(.rect)
  }

  private var owner: String {
    let name = bot?.name ?? "Deleted bot"
    return creator.map { "\(name) · by \($0.name)" } ?? name
  }

  private var status: some View {
    let symbol: String = switch schedule.status {
    case .active: "checkmark.circle.fill"
    case .paused: "pause.circle.fill"
    case .completed: "checkmark.circle"
    }
    return Label(schedule.status.label, systemImage: symbol)
      .labelStyle(.titleAndIcon)
      .foregroundStyle(schedule.status == .active ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
  }
}

private struct AutomationRunRow: View {
  let run: AutomationRun
  let bot: Agent?

  var body: some View {
    HStack(spacing: 10) {
      if let bot { BotAvatarView(agent: bot, size: 28) }
      VStack(alignment: .leading, spacing: 2) {
        Text(run.title).fontWeight(.semibold).lineLimit(1)
        Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if run.failed, let error = run.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
          Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      status
    }
    .contentShape(.rect)
  }

  private var details: String {
    var parts = [bot?.name ?? "Deleted bot", run.started.formatted(date: .abbreviated, time: .shortened)]
    if let script = run.script { parts.append(script.duration()) }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder private var status: some View {
    if run.running {
      HStack(spacing: 4) {
        ProgressView().controlSize(.small)
        Text(run.statusLabel)
      }
      .font(.caption)
    } else {
      Label(run.statusLabel, systemImage: run.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(run.failed ? .red : .green)
    }
  }
}

/// A script run's result: its status, exit code, timing and the tail of its output.
struct AutomationRunOutput: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let run: ScriptRun

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          Text(summary).font(.caption).foregroundStyle(.secondary)
          if let error = run.error { Text(error).font(.caption).foregroundStyle(.red) }
          if run.droppedBytes > 0 {
            Text("\(run.droppedBytes) bytes omitted").font(.caption).foregroundStyle(.secondary)
          }
          Text(run.output.isEmpty ? "No output" : run.output)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
        .padding()
      }
      .navigationTitle(title)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    #if os(macOS)
      .frame(width: 560, height: 460)
    #endif
  }

  private var summary: String {
    var parts = [run.status.label, "Exit code: \(run.exitCode.map(String.init) ?? "—")"]
    if let started = automationRunDate(run.startedAt) {
      parts.append(started.formatted(date: .abbreviated, time: .shortened))
    }
    parts.append("Duration: \(run.duration())")
    return parts.joined(separator: " · ")
  }
}
