import apfelkern
import SwiftUI

struct SkillsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var board = model.sharedSkillBoard
        let catalog = model.skillCatalog
        Form {
            SkillsStatusSection(catalog: catalog)
            if catalog.showsShared { sharedSection(catalog) }
            ForEach(catalog.visibleOwners) { owner in
                BotSkillsSection(
                    title: owner.agent.name, agentID: owner.id, agentName: owner.agent.name, catalog: catalog)
            }
            if catalog.showsDefaults { defaultSection(catalog) }
        }
        .formStyle(.grouped)
        .searchable(text: $board.search, prompt: "Search skills")
        .safeAreaInset(edge: .bottom) { SkillBulkBar(catalog: catalog) }
        .sheet(item: $board.sheet) { sheet in
            switch sheet {
            case .install(let install): SkillInstallSheet(install: install)
            case .view(let review): InstalledSkillSheet(review: review)
            case .update(let review): SkillUpdateSheet(review: review)
            }
        }
    }

    private func sharedSection(_ catalog: SkillCatalog) -> some View {
        Section {
            if catalog.visibleShared.isEmpty {
                Text(catalog.shared.isEmpty ? "No shared skills yet." : "No skills match your search.")
                    .foregroundStyle(.secondary)
            }
            ForEach(catalog.visibleShared) { SharedSkillRow(skill: $0) }
        } header: {
            HStack {
                Text("Shared")
                Spacer()
                SkillSelectBox(
                    ids: catalog.visibleShared.map(\.id).filter { !$0.hasPrefix("pending-") },
                    label: "Select all shared skills", title: "Select all")
            }
        } footer: {
            Text("Turn a shared skill on for the bots that should have it.").foregroundStyle(.secondary)
        }
    }

    private func defaultSection(_ catalog: SkillCatalog) -> some View {
        Section {
            if catalog.visibleDefaults.isEmpty {
                Text(catalog.defaults.isEmpty ? "No default skills." : "No skills match your search.")
                    .foregroundStyle(.secondary)
            }
            ForEach(catalog.visibleDefaults) { DefaultSkillRow(skill: $0) }
        } header: {
            Text("Default")
        } footer: {
            Text("Every bot has these. They're files on the server: edit them there and restart it.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The owner filter, and what the page has to say about the last check, read, or bulk action.
private struct SkillsStatusSection: View {
    @Environment(AppModel.self) private var model
    let catalog: SkillCatalog

    var body: some View {
        @Bindable var board = model.sharedSkillBoard
        Section {
            if let error = board.readError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button("Retry") { model.reloadSkills() }
            }
            if let error = board.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(board.checkFailures, id: \.self) {
                Text($0).foregroundStyle(.red).textSelection(.enabled)
            }
            if board.checking {
                Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.skillBulkBoard.report) { line in
                Text(line.text).font(.callout).textSelection(.enabled)
            }
            Picker("Whose skills", selection: $board.scope) {
                ForEach(catalog.options) { Text($0.title).tag($0.scope) }
            }
            SkillSelectBox(ids: catalog.visibleIDs, label: "Select all results", title: "Select all")
        }
    }
}

/// A checkbox for one skill or a group of them, mixed while the group is partly selected.
struct SkillSelectBox: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    let label: String
    var title: String?

    private var board: SkillBulkBoard { model.skillBulkBoard }

    private var symbol: String {
        switch board.state(of: ids) {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }

    var body: some View {
        if !ids.isEmpty {
            Button {
                board.change(ids, isOn: board.state(of: ids) != .all)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(.tint)
                    if let title { Text(title).font(.caption) }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
            .accessibilityValue(board.state(of: ids) == .none ? "Off" : board.state(of: ids) == .all ? "On" : "Mixed")
            .disabled(board.isRunning)
        }
    }
}

private struct SharedSkillRow: View {
    @Environment(AppModel.self) private var model
    let skill: SharedSkill
    @State private var deleting = false

    private var isBusy: Bool {
        skill.id.hasPrefix("pending-") || model.sharedSkillBoard.pending.contains(skill.id)
    }

    private var usage: Int { model.agents.using(skill: skill.id).count }

    var body: some View {
        HStack {
            if !skill.id.hasPrefix("pending-") {
                SkillSelectBox(ids: [skill.id], label: "Select \(skill.name) (Shared)")
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name).fontWeight(.semibold)
                        if let update = skill.update {
                            SkillBadge(text: update.badge, prominent: !update.removed)
                        }
                    }
                    Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            if usage > 0 { Text("(used by \(usage))").font(.caption).foregroundStyle(.secondary) }
            menu
        }
        .confirmationDialog(
            "\(skill.isInstalled ? "Uninstall" : "Delete") \(skill.name)?", isPresented: $deleting,
            titleVisibility: .visible
        ) {
            Button(skill.isInstalled ? "Uninstall" : "Delete", role: .destructive) {
                model.deleteSharedSkill(skill.id)
            }
        } message: {
            Text(
                skill.isInstalled
                    ? "Every bot that uses it loses it. You can install it again from GitHub."
                    : "Every bot that uses it loses it. This cannot be undone.")
        }
    }

    private func open() {
        if skill.isInstalled { model.openInstalledSkill(skill) } else { model.openSkillForm(skill.id) }
    }

    private var menu: some View {
        Menu {
            if skill.isInstalled {
                Button("View", action: open)
                if let update = skill.update, !update.removed {
                    Button("Update") { model.openSkillUpdate(skill) }
                }
                Button("Make a copy") { model.copySharedSkill(skill) }
                Divider()
                Button("Uninstall…", role: .destructive) { deleting = true }
            } else {
                Button("Edit", action: open)
                Divider()
                Button("Delete…", role: .destructive) { deleting = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Skill actions")
        .disabled(isBusy)
    }
}

struct SkillBadge: View {
    let text: String
    let prominent: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(prominent ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.quaternary))
    }
}

private struct DefaultSkillRow: View {
    let skill: SharedSkill

    var body: some View {
        DisclosureGroup {
            Text(skill.instructions.isEmpty ? "No instructions." : skill.instructions)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let path = skill.path, !path.isEmpty {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).fontWeight(.semibold)
                Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
