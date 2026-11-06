import apfelkern
import BotAvatar
import SwiftUI

struct ActivityPanel: View {
    @Environment(AppModel.self) private var model

    private var board: ActivityBoard { model.activityBoard }

    private var kind: Binding<ActivityKind?> {
        Binding(get: { board.kind }, set: { model.showActivity(kind: $0, botID: board.botID) })
    }

    private var bot: Binding<String?> {
        Binding(get: { board.botID }, set: { model.showActivity(kind: board.kind, botID: $0) })
    }

    private var pills: [FilterPill<ActivityKind?>] {
        [FilterPill(value: nil, label: "All")]
            + ActivityKind.allCases.map { FilterPill(value: $0, label: $0.label, symbol: $0.symbol) }
    }

    var body: some View {
        Form {
            Section {
                FilterPills(label: "Kind of activity", pills: pills, selection: kind)
                Picker("Bot", selection: bot) {
                    Text("All bots").tag(String?.none)
                    ForEach(model.agents) { Text($0.name).tag(String?.some($0.id)) }
                }
            }
            if board.kind == .change {
                ChangeList()
            } else {
                feed
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var feed: some View {
        if let error = board.readError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        if !board.isLoaded, board.readError == nil {
            ProgressView()
        } else if board.isLoaded, board.entries.isEmpty, !board.hasMore {
            ContentUnavailableView(
                "No Activity", systemImage: "waveform.path.ecg", description: Text(board.emptyText))
        }
        ForEach(activityDays(board.entries, date: \.date)) { day in
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
        if board.hasMore {
            Section {
                Button(board.isLoadingMore ? "Loading…" : "Show older activity") { model.loadMoreActivity() }
                    .disabled(board.isLoadingMore)
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
