import apfelkern
import BotAvatar
import SwiftUI

/// A group in the sidebar: its members' avatars overlapping, its name, and who is in it.
struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: GroupChat

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
            Button("Delete Group", role: .destructive) { model.deleteGroup(group.id) }
        }
    }
}

/// One row of a group transcript.
enum GroupChatRow: Identifiable {
    case older
    case time(String, String)
    case message(Message, reactions: [Reaction.Mark])
    case working([Agent])
    case failure(Agent, String)
    case paused

    var id: String {
        switch self {
        case .older: "older"
        case .time(let id, _): "time:" + id
        case .message(let message, _): message.id
        case .working: "working"
        case .failure(let agent, _): "failure:" + agent.id
        case .paused: "paused"
        }
    }

    /// Owner and bot messages with reactions beside the message they answer, then who is answering,
    /// failed turns, and the paused state.
    static func rows(messages: [Message], snapshot: GroupChatSnapshot?, agents: [Agent], hasMore: Bool)
        -> [GroupChatRow] {
        var rows: [GroupChatRow] = hasMore ? [.older] : []
        var last: Int64 = 0
        let reactions = Reaction.byReplyTarget(messages)
        for message in messages where message.role == "user" || message.role == "assistant" {
            if let timestamp = message.timestamp, timestamp > 0 {
                if timestamp - last > 30 * 60 * 1000 {
                    rows.append(.time(message.id, timeLabel(Date(timeIntervalSince1970: Double(timestamp) / 1000))))
                }
                last = timestamp
            }
            rows.append(.message(message, reactions: reactions[message.id] ?? []))
        }
        guard let snapshot else { return rows }
        let agent = { (id: String) in agents.first { $0.id == id } }
        let working = snapshot.activity.members.filter { $0.status == .running }.compactMap { agent($0.agentId) }
        if !working.isEmpty { rows.append(.working(working)) }
        for member in snapshot.activity.members {
            if let error = member.error?.nilIfEmpty, let bot = agent(member.agentId) {
                rows.append(.failure(bot, error))
            }
        }
        if snapshot.activity.paused { rows.append(.paused) }
        return rows
    }
}

struct GroupChatView: View {
    @Environment(AppModel.self) private var model
    let group: GroupChat

    private var members: [Agent] { group.memberIds.compactMap { id in model.agents.first { $0.id == id } } }

    var body: some View {
        let rows = GroupChatRow.rows(
            messages: model.messages, snapshot: model.groupSnapshot, agents: model.agents, hasMore: model.hasMore)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    GroupChatRowView(row: row).padding(.top, index > 0 ? 12 : 0)
                }
            }
            .frame(maxWidth: Palette.column)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
                        .help(memberHelp(agent, status))
                        .accessibilityLabel(memberHelp(agent, status))
                }
            }
        }
    }

    private func memberHelp(_ agent: Agent, _ status: GroupMemberActivity.Status) -> String {
        switch status {
        case .running: "\(agent.name) is answering"
        case .queued: "\(agent.name) answers next"
        case .disabled: "\(agent.name) is disabled and skipped"
        case .idle: agent.name
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
        case .failure(let agent, let error):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(agent.name) couldn’t finish").font(.system(size: 14, weight: .medium))
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
        MarkdownText(text: message.text)
            .font(Palette.messageFont)
            .lineSpacing(Palette.messageLineSpacing)
            .textSelection(.enabled)
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

/// Creates or edits a group: its name and two to six member bots.
struct GroupEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: GroupDraft

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            Section {
                ForEach(model.agents) { agent in
                    Toggle(isOn: Binding(
                        get: { draft.memberIDs.contains(agent.id) },
                        set: { included in
                            if included {
                                if !draft.memberIDs.contains(agent.id) { draft.memberIDs.append(agent.id) }
                            } else {
                                draft.memberIDs.removeAll { $0 == agent.id }
                            }
                        })
                    ) {
                        HStack(spacing: 8) {
                            BotAvatarView(agent: agent, size: 22, state: .idle)
                            Text(agent.name)
                            if !agent.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(!draft.memberIDs.contains(agent.id)
                        && draft.memberIDs.count >= GroupDraft.memberRange.upperBound)
                }
            } header: {
                Text("Members")
            } footer: {
                Text("Choose two to six bots. A bot added later gets a summary of the conversation so far.")
            }
            SheetError()
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 480)
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
