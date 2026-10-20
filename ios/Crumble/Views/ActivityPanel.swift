import apfelkern
import SwiftUI

struct ActivityPanel: View {
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
                DisclosureGroup("Details") {
                  Text(JSONValue.object(activity.details).prettyPrinted).font(.caption.monospaced()).textSelection(.enabled)
                }
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
