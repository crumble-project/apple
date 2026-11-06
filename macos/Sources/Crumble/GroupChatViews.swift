import apfelkern
import BotAvatar
import SwiftUI

/// A group in the sidebar: its members' avatars overlapping, its name, and who is in it.
struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: GroupChat
    @State private var confirmingDelete = false

    private var members: [Agent] { group.memberIds.compactMap { id in model.agents.first { $0.id == id } } }

    var body: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(members.prefix(2).enumerated()), id: \.element.id) { index, agent in
                    BotAvatarView(agent: agent, size: 26, state: .idle)
                        .offset(x: CGFloat(index) * 12, y: CGFloat(index) * 12)
                }
            }
            .frame(width: 38, height: 38, alignment: .topLeading)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).lineLimit(1)
                Text(members.map(\.name).formatted(.list(type: .and)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit Group…") { model.editGroup(group) }
            Button("Delete Group…", role: .destructive) { confirmingDelete = true }
        }
        .confirmsGroupDeletion(name: group.name, isPresented: $confirmingDelete) { model.deleteGroup(group.id) }
    }
}

extension View {
    /// Group deletion can't be undone, so both the row and the editor ask first.
    func confirmsGroupDeletion(
        name: String, isPresented: Binding<Bool>, delete: @escaping () -> Void
    ) -> some View {
        confirmationDialog("Delete \(name)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("The group chat and its messages will be removed. The bots stay. This cannot be undone.")
        }
    }
}

struct GroupChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: GroupChat

    private var members: [Agent] { group.memberIds.compactMap { id in model.agents.first { $0.id == id } } }

    var body: some View {
        let rows = GroupChatRow.rows(
            messages: model.messages, snapshot: model.groupSnapshot, agents: model.agents, hasMore: model.hasMore)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    GroupChatRowView(row: row)
                        .padding(.top, index > 0 ? 12 : 0)
                        .transition(.groupArrival)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.groupArrivals)
            .frame(maxWidth: Palette.column)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .jumpToLatest()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .overlay {
            if rows.isEmpty {
                if model.groupSnapshot == nil {
                    ProgressView()
                } else {
                    VStack(spacing: 4) {
                        Text("Start the conversation").font(.system(size: 15, weight: .medium))
                        Text("Everyone here reads every message. Mention a bot with @ to ask only it.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .padding(.bottom, 60)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.groupSnapshot != nil { Composer(target: composerTarget) }
        }
        .navigationTitle(group.name)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) { GroupMembersStrip(group: group) }
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button("Edit Group", systemImage: "person.2.badge.gearshape") { model.editGroup(group) }
                    .help("Edit Group")
            }
        }
    }

    private var composerTarget: ComposerTarget {
        ComposerTarget(
            placeholder: "Message \(group.name)",
            enabled: true,
            mentionable: members.filter(\.enabled),
            running: model.groupSnapshot?.activity.isRunning == true,
            stopHelp: "Stop every bot in this group",
            send: { model.sendGroupMessage() },
            stop: { model.stopGroup() })
    }
}

extension AnyTransition {
    /// A new message rises into place as it fades in, as on the web.
    static var groupArrival: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .identity)
    }
}

/// The group's members with what each is doing: answering, waiting for a turn, or disabled.
struct GroupMembersStrip: View {
    @Environment(AppModel.self) private var model
    let group: GroupChat

    var body: some View {
        HStack(spacing: 4) {
            Text(group.name).font(.headline).padding(.trailing, 6)
            ForEach(group.memberIds, id: \.self) { id in
                if let agent = model.agents.first(where: { $0.id == id }) {
                    let status = model.groupSnapshot?.activity.member(id)?.status ?? .idle
                    BotAvatarView(agent: agent, size: 22, state: status == .running ? .working : .idle)
                        .opacity(status == .disabled ? 0.4 : 1)
                        .help(status.label(for: agent.name))
                        .accessibilityLabel(status.label(for: agent.name))
                }
            }
        }
    }
}

struct GroupChatRowView: View {
    @Environment(AppModel.self) private var model
    let row: GroupChatRow

    var body: some View {
        switch row {
        case .older:
            if model.loadingOlder {
                ProgressView().controlSize(.small)
            } else {
                Button("Load Earlier Messages") { model.loadOlder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        case .time(_, let label):
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .message(let message, let reactions):
            if message.role == "user" {
                MessageView(message: message, reactions: reactions.map(\.emoji))
            } else {
                GroupBotMessage(message: message, reactions: reactions)
            }
        case .working(let agents):
            HStack(spacing: 8) {
                ForEach(agents) { BotAvatarView(agent: $0, size: 22, state: .working) }
                TypingDots()
                    .padding(.horizontal, 15)
                    .padding(.vertical, 14)
                    .background(Palette.bubble, in: .rect(cornerRadius: 18))
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(agents.map(\.name).formatted(.list(type: .and))) answering…")
        case .failure(_, let name, let error):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name) couldn’t finish").font(.system(size: 14, weight: .medium))
                    Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.red.opacity(0.06), in: .rect(cornerRadius: 14))
                .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 0)
            }
        case .paused:
            Label("The bots are waiting for you. Your next message lets them continue.", systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A bot's message in a group: who wrote it, its text, and the reactions it got.
struct GroupBotMessage: View {
    @Environment(AppModel.self) private var model
    let message: Message
    var reactions: [Reaction.Mark] = []
    @State private var hovered = false

    private var sender: Agent? { model.agents.first { $0.id == message.origin?.agentId } }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                Text(message.origin?.name ?? sender?.name ?? "A bot")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sender?.color ?? .secondary)
                bubble
            }
            replyButton
            Spacer(minLength: 56)
        }
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var avatar: some View {
        Group {
            if let sender {
                BotAvatarView(agent: sender, size: 28, state: .idle)
            } else {
                Image(systemName: "person.crop.circle").font(.system(size: 24)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var bubble: some View {
        let reply = SourceCitations.split(message.text, sources: message.sources ?? [])
        return VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text: reply.text)
                .font(Palette.messageFont)
                .lineSpacing(Palette.messageLineSpacing)
                .textSelection(.enabled)
            ForEach(reply.chips, id: \.href) { SourceChipLink(chip: $0) }
        }
        .bubble(owner: false)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottomTrailing) {
            if !reactions.isEmpty {
                ReactionBadge(reactions: reactions.map(\.emoji))
                    .offset(x: 8, y: 16)
                    .help(reactions.map { "\($0.from ?? "A bot") \($0.emoji)" }.joined(separator: ", "))
            }
        }
        .padding(.bottom, reactions.isEmpty ? 0 : 14)
        .contextMenu {
            Button("Reply") { model.replyTo = message }
            Button("Copy") { copy() }
        }
    }

    private var replyButton: some View {
        Button {
            model.replyTo = message
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply")
        .help("Reply")
        .opacity(hovered ? 1 : 0)
        .padding(.top, 20)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

/// A page the reply's turn read, opened in the browser.
struct SourceChipLink: View {
    let chip: SourceChip

    var body: some View {
        if let url = URL(string: chip.href) {
            Link(destination: url) {
                Label(chip.title.nilIfEmpty ?? chip.href, systemImage: "link")
                    .font(.callout)
                    .lineLimit(1)
            }
            .help(chip.href)
        }
    }
}

/// Creates or edits a group: its name and two to six member bots.
struct GroupEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: GroupDraft
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
                .onChange(of: draft.name) { _, name in
                    if name.count > GroupDraft.nameLimit { draft.name = String(name.prefix(GroupDraft.nameLimit)) }
                }
            Section {
                ForEach(model.agents) { agent in
                    Toggle(isOn: Binding(
                        get: { draft.includes(agent.id) },
                        set: { draft.setMember(agent.id, included: $0) })
                    ) {
                        HStack(spacing: 8) {
                            BotAvatarView(agent: agent, size: 22, state: .idle)
                            Text(agent.name)
                            if !agent.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(!draft.includes(agent.id) && draft.isFull)
                }
            } header: {
                Text("Members")
            } footer: {
                Text("Choose two to six bots. A bot added later gets a summary of the conversation so far.")
            }
            if draft.groupID != nil {
                Section {
                    Button("Delete Group…", role: .destructive) { confirmingDelete = true }
                }
            }
            SheetError()
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 480)
        .confirmsGroupDeletion(name: draft.name, isPresented: $confirmingDelete) {
            guard let id = draft.groupID else { return }
            model.groupDraft = nil
            model.deleteGroup(id)
            dismiss()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.groupDraft = nil
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.groupID == nil ? "Create" : "Save") { model.saveGroup(draft) }
                    .disabled(!draft.isValid)
            }
        }
    }
}
