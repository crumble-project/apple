import apfelkern
import SwiftUI

private enum ActivityFilter: String, CaseIterable {
  case all = "All", changes = "Changes"
}

struct ActivityPanel: View {
  @Environment(AppModel.self) private var model
  @State private var filter = ActivityFilter.all

  var body: some View {
    Form {
      Section {
        Picker("Show", selection: $filter) {
          ForEach(ActivityFilter.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      switch filter {
      case .all: everything
      case .changes: ChangeList()
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private var everything: some View {
    if model.activities.isEmpty {
      ContentUnavailableView(
        "No Activity", systemImage: "waveform.path.ecg",
        description: Text("Tool calls, bot messages, and skill and memory changes will appear here."))
    }
    ForEach(activityDays(model.activities, date: \.date)) { day in
      Section(day.label) {
        ForEach(day.items) { activity in
          if let change = activity.change {
            ChangeRow(change: change, botName: activity.agentName, time: activityTime(activity.timestamp))
          } else {
            row(activity)
          }
        }
      }
    }
  }

  private func row(_ activity: ActivityEntry) -> some View {
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
        Text(activity.agentName ?? "").font(.headline)
        Text(activitySummary(activity)).lineLimit(2)
        DisclosureGroup("Details") {
          Text(JSONValue.object(activity.details).prettyPrinted).font(.caption.monospaced()).textSelection(.enabled)
        }
      }
      Spacer()
      if let id = activity.agentId { Button("Open Chat") { model.selectAgent(id) } }
    }
  }

  private func activitySummary(_ activity: ActivityEntry) -> String {
    let details = activity.details
    if let tool = details["toolName"]?.stringValue ?? details["name"]?.stringValue {
      if let status = details["status"]?.stringValue { return "\(tool) · \(status)" }
      return tool
    }
    if let from = details["from"]?.stringValue, let destination = details["to"]?.stringValue {
      return "\(from) → \(destination)"
    }
    return details["content"]?.stringValue ?? activity.kind.replacingOccurrences(of: "-", with: " ").capitalized
  }
}
