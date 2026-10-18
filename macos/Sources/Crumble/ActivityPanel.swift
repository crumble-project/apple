import AuthenticationServices
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
                                    Text(title(for: activity))
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: .capsule)
                                    Text(
                                        activity.timestamp.map {
                                            timeLabel(Date(timeIntervalSince1970: Double($0) / 1000))
                                        } ?? ""
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    Text(activity.agentName).font(.caption).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Details") {
                                    Text(details(for: activity))
                                        .font(.callout)
                                        .textSelection(.enabled)
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
            let from = activity.details["communication"]?["fromName"]?.stringValue ?? activity.agentName
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
