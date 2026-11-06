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
