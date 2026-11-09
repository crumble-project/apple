import apfelkern
import SwiftUI

extension View {
  /// Trims text past a limit as it is typed, which a binding's setter can't: a field whose
  /// state didn't change keeps showing the extra characters.
  func limited(_ text: Binding<String>, by limit: @escaping (String) -> String) -> some View {
    onChange(of: text.wrappedValue) { _, new in
      let allowed = limit(new)
      if allowed != new { text.wrappedValue = allowed }
    }
  }
}

/// Which bots use a skill.
struct SkillUsedBySection: View {
  @Environment(AppModel.self) private var model
  @Binding var selected: Set<String>
  var title = "Used by"

  var body: some View {
    if !model.agents.isEmpty {
      Section(title) {
        ForEach(model.agents) { agent in
          Toggle(
            agent.name,
            isOn: Binding(
              get: { selected.contains(agent.id) },
              set: { isOn in
                if isOn { selected.insert(agent.id) } else { selected.remove(agent.id) }
              })
          )
        }
      }
    }
  }
}

private struct SkillSheetError: View {
  let text: String?

  var body: some View {
    if let text {
      Section {
        Label(text, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    }
  }
}

struct SkillInstallSheet: View {
  @Environment(AppModel.self) private var model
  let install: SkillInstall

  var body: some View {
    @Bindable var install = install
    NavigationStack {
      Form {
        SkillSheetError(text: install.error)
        Section {
          HStack {
            TextField(
              "Repository", text: Binding(get: { install.location }, set: { install.setLocation($0) }),
              prompt: Text("owner/repo")
            )
            .accessibilityLabel("Repository")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            if install.listing != nil {
              Button("Find") { model.findSkills(install) }.disabled(install.browsing || install.installing)
            }
          }
          if install.browsing { ProgressView().controlSize(.small) }
        } footer: {
          Text("""
            Installed skills are shared and read-only. You can update them when the repository changes. \
            Use a public repository, or a github.com link to a folder in one.
            """).foregroundStyle(.secondary)
        }
        if let listing = install.listing {
          candidates(listing)
          SkillUsedBySection(selected: $install.botIDs)
        }
      }
      .formStyle(.grouped)
      .interactiveDismissDisabled(install.installing)
      .navigationTitle("Install from GitHub")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) { model.sharedSkillBoard.sheet = nil }.disabled(install.installing)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(install.installing ? "Installing…" : install.actionLabel) {
            model.runSkillInstallAction(install)
          }
          .disabled(!install.actionReady)
        }
      }
    }
  }

  private func candidates(_ listing: SkillListing) -> some View {
    Section {
      if listing.skills.isEmpty {
        Text("No folder here has a SKILL.md.").foregroundStyle(.secondary)
      }
      ForEach(listing.skills) { candidate in
        Toggle(
          isOn: Binding(
            get: { install.picked.contains(candidate.path) },
            set: { install.toggle(candidate.path, isOn: $0) })
        ) {
          candidateLabel(candidate)
        }
        .disabled(!candidate.isSelectable)
      }
    } header: {
      Text("Skills in \(listing.repository) (\(listing.branch))")
    } footer: {
      if listing.omitted > 0 {
        Text("\(listing.omitted) more aren't listed. Link to a folder to see them.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func candidateLabel(_ candidate: SkillCandidate) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(candidate.name).fontWeight(.medium)
        if let status = candidate.statusLabel { SkillBadge(text: status, prominent: false) }
      }
      if !candidate.description.isEmpty {
        Text(candidate.description).font(.caption).foregroundStyle(.secondary)
      }
      if let note = candidate.note {
        Text(note).font(.caption).foregroundStyle(candidate.problem == nil ? Color.secondary : .red)
      }
    }
  }
}

/// An installed skill, read-only: Used by is the one thing here that can change.
struct InstalledSkillSheet: View {
  @Environment(AppModel.self) private var model
  let review: SkillReview

  private var skill: SharedSkill { review.skill }

  var body: some View {
    @Bindable var review = review
    NavigationStack {
      Form {
        SkillSheetError(text: review.error)
        Section {
          source
          Button("Make a copy") {
            model.copySharedSkill(skill)
            model.sharedSkillBoard.sheet = nil
          }
        } footer: {
          Text("Installed skills are read-only. Make a copy to change one.").foregroundStyle(.secondary)
        }
        SkillUsedBySection(selected: $review.usedBy)
        if let update = skill.update { updateNotice(update) }
        content
      }
      .formStyle(.grouped)
      .navigationTitle(skill.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) { model.sharedSkillBoard.sheet = nil }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .confirm) {
            model.assignSharedSkill(skill.id, usedBy: review.usedBy)
            model.sharedSkillBoard.sheet = nil
          }
        }
      }
    }
  }

  @ViewBuilder private var source: some View {
    if let origin = skill.origin {
      VStack(alignment: .leading, spacing: 2) {
        if let url = origin.url { Link(origin.folderName, destination: url) }
        Text("On \(origin.branch), commit \(origin.shortCommit).")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func updateNotice(_ update: SkillUpdate) -> some View {
    Section {
      HStack {
        Text(update.removed ? "This skill is no longer in the repository." : "A newer version is available.")
        Spacer()
        if !update.removed {
          Button("Review update") { model.openSkillUpdate(skill) }
        }
      }
    }
  }

  @ViewBuilder private var content: some View {
    if let package = review.package {
      Section("Instructions") {
        if !package.description.isEmpty { Text(package.description) }
        Text(package.instructions)
          .font(.footnote.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if !package.documents.isEmpty {
        Section("Reference documents") {
          ForEach(package.documents) { Text($0.path).font(.caption.monospaced()) }
        }
      }
    } else if review.error == nil {
      ProgressView()
    }
  }
}

/// What an update would change. It depends on GitHub, so the sheet stays until the server answers.
struct SkillUpdateSheet: View {
  @Environment(AppModel.self) private var model
  let review: SkillReview

  var body: some View {
    NavigationStack {
      Form {
        SkillSheetError(text: review.error)
        Section {
          if let diff = review.diff {
            SkillDiffView(lines: diff)
          } else if review.error == nil {
            ProgressView()
          }
          if let note = review.skippedNote {
            Text(note).font(.caption).foregroundStyle(.secondary)
          }
        } footer: {
          Text("The update is recorded in the change log, so you can revert it.").foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .interactiveDismissDisabled(review.applying)
      .navigationTitle("Update \(review.skill.name)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .cancel) { model.sharedSkillBoard.sheet = nil }.disabled(review.applying)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(review.applying ? "Updating…" : "Update") { model.applySkillUpdate(review) }
            .disabled(review.pendingUpdate == nil || review.applying)
        }
      }
    }
  }
}

struct SkillDiffView: View {
  let lines: [SkillDiffLine]

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text("\(line.kind.rawValue) \(line.text)")
          .font(.caption.monospaced())
          .foregroundStyle(color(line.kind))
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(color(line.kind).opacity(line.kind == .same ? 0 : 0.1))
          .accessibilityLabel(accessibility(line))
      }
    }
    .textSelection(.enabled)
  }

  private func color(_ kind: SkillDiffLine.Kind) -> Color {
    switch kind {
    case .same: .secondary
    case .removed: .red
    case .added: .green
    }
  }

  private func accessibility(_ line: SkillDiffLine) -> String {
    switch line.kind {
    case .same: line.text
    case .removed: "Removed: " + line.text
    case .added: "Added: " + line.text
    }
  }
}
