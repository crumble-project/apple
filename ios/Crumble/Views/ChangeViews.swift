import apfelkern
import SwiftUI

/// The Changes view of the Activity page, by day as on the web.
struct ChangeList: View {
  @Environment(AppModel.self) private var model

  private var board: ChangeBoard { model.changeBoard }

  var body: some View {
    Section {
      if let error = board.readError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if !board.isLoaded, board.readError == nil {
        ProgressView()
      } else if board.isLoaded, board.changes.isEmpty {
        Text("Nothing of this kind yet.").foregroundStyle(.secondary)
      }
    }
    ForEach(activityDays(board.changes, date: \.createdDate)) { day in
      Section(day.label) {
        ForEach(day.items) { change in
          ChangeRow(
            change: change, botName: model.agents.first { $0.id == change.agentID }?.name,
            time: activityTime(change.createdAt))
        }
      }
    }
    if board.hasMore {
      Section {
        Button(board.isLoadingMore ? "Loading…" : "Show older changes") { model.loadMoreChanges() }
          .disabled(board.isLoadingMore)
      }
    }
  }
}

/// Expands to the change's diff and Revert, which asks first as on the web.
struct ChangeRow: View {
  @Environment(AppModel.self) private var model
  let change: LearnedChange
  let botName: String?
  let time: String
  @State private var expanded = false
  @State private var confirmingRevert = false

  private var board: ChangeBoard { model.changeBoard }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      if expanded {
        SkillDiffView(lines: change.diff)
        if let error = board.errors[change.id] {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        Button(board.isReverting(change) ? "Reverting…" : "Revert") { confirmingRevert = true }
          .disabled(board.isReverting(change))
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(change.summary(botName: botName)).fontWeight(.medium)
        Text(change.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if !time.isEmpty { Text(time).font(.caption).foregroundStyle(.secondary) }
      }
    }
    .alert(change.revertTitle, isPresented: $confirmingRevert) {
      Button("Cancel", role: .cancel) {}
      Button("Revert") { model.revertChange(change) }
    } message: {
      Text(change.revertNote)
    }
  }
}
