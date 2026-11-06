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
                        ChangeRow(
                            change: change, botName: activity.agentName, time: activityTime(activity.timestamp))
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
                    Text(title(for: activity))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                    Text(activityTime(activity.timestamp)).font(.caption).foregroundStyle(.secondary)
                    Text(activity.agentName ?? "").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Details") {
                    Text(details(for: activity))
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let id = activity.agentId { Button("Open Chat") { model.selectAgent(id) } }
        }
    }

    private func title(for activity: ActivityEntry) -> String {
        switch activity.kind {
        case "tool-call":
            return "Tool call · "
                + (activity.details["toolName"]?.stringValue ?? activity.details["name"]?.stringValue ?? "Unknown tool")
        case "tool-result":
            return "Tool result · "
                + (activity.details["toolName"]?.stringValue ?? activity.details["name"]?.stringValue ?? "Unknown tool")
        case "mcp-call":
            return "MCP call · "
                + (activity.details["name"]?.stringValue ?? activity.details["toolName"]?.stringValue
                    ?? "Unknown server")
        case "bot-message":
            let from = activity.details["communication"]?["fromName"]?.stringValue ?? activity.agentName ?? ""
            let recipient = activity.details["communication"]?["toName"]?.stringValue ?? "another bot"
            return "Bot message · \(from) → \(recipient)"
        default: return activity.kind.capitalized
        }
    }

    private func details(for activity: ActivityEntry) -> String {
        if activity.kind == "bot-message", let content = activity.details["content"]?.stringValue { return content }
        return activity.details.map { "\($0.key): \($0.value.prettyPrinted)" }.sorted().joined(separator: "\n")
    }
}
