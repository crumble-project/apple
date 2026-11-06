import apfelkern
import SwiftUI

/// Acts on the selected skills. Assigning and removing ask which bots, and deleting asks first.
struct SkillBulkBar: View {
  @Environment(AppModel.self) private var model
  let catalog: SkillCatalog
  @State private var targeting: BulkSkillAction?
  @State private var deleting = false

  private var board: SkillBulkBoard { model.skillBulkBoard }

  var body: some View {
    let picked = catalog.picked(board.selected)
    if !picked.isEmpty || board.isRunning {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Button("Clear selection", systemImage: "xmark", action: board.clear)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
          Text("\(board.isRunning ? board.runningCount : picked.count) selected")
            .font(.subheadline.weight(.medium)).monospacedDigit()
          Spacer(minLength: 8)
          Menu("Actions") {
            ForEach(BulkSkillAction.allCases) { action($0, picked: picked) }
          }
        }
        if let note = picked.updateNote {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
        if board.isRunning {
          Text("Applying action…").font(.caption).foregroundStyle(.secondary)
        }
      }
      .disabled(board.isRunning)
      .padding(10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      .padding(10)
      .confirmationDialog("Delete \(picked.count) skills?", isPresented: $deleting, titleVisibility: .visible) {
        Button("Delete", role: .destructive) { model.runBulkSkillAction(.delete) }
      } message: {
        Text(picked.deleteWarning)
      }
      .sheet(item: $targeting) { SkillTargetsSheet(action: $0, picked: picked) }
    }
  }

  private func action(_ action: BulkSkillAction, picked: [SelectableSkill]) -> some View {
    Button(action.label, role: action == .delete ? .destructive : nil) {
      switch action {
      case .update: model.runBulkSkillAction(.update)
      case .assign, .remove: targeting = action
      case .delete: deleting = true
      }
    }
    .disabled(action.isDisabled(for: picked, hasBots: !model.agents.isEmpty))
  }
}

private struct SkillTargetsSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let action: BulkSkillAction
  let picked: [SelectableSkill]
  @State private var targets: Set<String> = []

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(action.explanation)
          Text(picked.labels).foregroundStyle(.secondary)
        }
        SkillUsedBySection(selected: $targets, title: "Choose bots")
      }
      .formStyle(.grouped)
      .navigationTitle(action.label)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(action.confirmation) {
            model.runBulkSkillAction(action, targets: targets)
            dismiss()
          }
          .disabled(targets.isEmpty)
        }
      }
    }
  }
}
