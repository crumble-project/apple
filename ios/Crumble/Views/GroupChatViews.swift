import apfelkern
import BotAvatar
import SwiftUI

/// A group in the sidebar: its members' avatars overlapping, its name, and who is in it.
struct GroupRow: View {
  @Environment(AppModel.self) private var model
  let group: GroupChat
  @State private var confirmingDelete = false

  private var members: [Agent] {
    group.memberIds.compactMap { id in model.agents.first { $0.id == id } }
  }

  var body: some View {
    NavigationLink(value: Route.group(group.id)) {
      HStack(spacing: 12) {
        ZStack(alignment: .topLeading) {
          ForEach(Array(members.prefix(2).enumerated()), id: \.element.id) { index, agent in
            BotAvatarView(agent: agent, size: 30, state: .idle)
              .offset(x: CGFloat(index) * 14, y: CGFloat(index) * 14)
          }
        }
        .frame(width: 44, height: 44, alignment: .topLeading)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(group.name).font(.headline).lineLimit(1)
          Text(members.map(\.name).formatted(.list(type: .and)))
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .padding(.vertical, 4)
    }
    .disabled(model.pendingMutations.contains("group:\(group.id)") || group.id.hasPrefix("local:"))
    .contextMenu {
      Button("Edit Group…", systemImage: "pencil") { model.editGroup(group) }
      Button("Delete Group…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
    }
    .swipeActions {
      Button("Delete", systemImage: "trash") { confirmingDelete = true }.tint(.red)
    }
    .confirmsGroupDeletion(name: group.name, isPresented: $confirmingDelete) {
      model.deleteGroup(group.id)
    }
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
  let group: GroupChat

  private var members: [Agent] {
    group.memberIds.compactMap { id in model.agents.first { $0.id == id } }
  }

  var body: some View {
    let rows = GroupChatRow.rows(
      messages: model.messages, snapshot: model.groupSnapshot, agents: model.agents,
      hasMore: model.hasMore)
    ScrollView {
      LazyVStack(spacing: 10) {
        ForEach(rows) { GroupChatRowView(row: $0) }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .overlay {
      if rows.isEmpty {
        if model.groupSnapshot == nil {
          ProgressView()
        } else {
          VStack(spacing: 10) {
            Text("Start the conversation").font(.title2.bold())
            Text("Everyone here reads every message. Mention a bot with @ to ask only it.")
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 420)
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 60)
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if model.groupSnapshot != nil { Composer(target: composerTarget) }
    }
    .navigationTitle(group.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) { GroupMembersStrip(group: group) }
        .sharedBackgroundVisibility(.hidden)
      ToolbarItem(placement: .primaryAction) {
        Button("Edit Group", systemImage: "pencil") { model.editGroup(group) }
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

/// The group's name over its members, showing what each is doing: answering, waiting, or disabled.
struct GroupMembersStrip: View {
  @Environment(AppModel.self) private var model
  let group: GroupChat

  var body: some View {
    VStack(spacing: 2) {
      Text(group.name).font(.headline).lineLimit(1)
      HStack(spacing: 2) {
        ForEach(group.memberIds, id: \.self) { id in
          if let agent = model.agents.first(where: { $0.id == id }) {
            let status = model.groupSnapshot?.activity.member(id)?.status ?? .idle
            BotAvatarView(agent: agent, size: 18, state: status == .running ? .working : .idle)
              .opacity(status == .disabled ? 0.4 : 1)
              .accessibilityElement()
              .accessibilityLabel(status.label(for: agent.name))
          }
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
      }
    case .time(_, let label):
      Text(label).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
    case .message(let message, let reactions):
      if message.role == "user" {
        MessageView(message: message, reactions: reactions.map(\.emoji))
      } else {
        GroupBotMessage(message: message, reactions: reactions)
      }
    case .working(let agents):
      HStack(spacing: 8) {
        HStack(spacing: -6) {
          ForEach(agents) { BotAvatarView(agent: $0, size: 24, state: .working, live: true) }
        }
        Text("\(agents.map(\.name).formatted(.list(type: .and))) answering…")
          .font(.callout).foregroundStyle(.secondary)
        Spacer()
      }
    case .failure(_, let name, let error):
      HStack {
        VStack(alignment: .leading, spacing: 8) {
          Text("\(name) couldn’t finish").font(.headline)
          Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
        .padding(14)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 12))
        .frame(maxWidth: 560, alignment: .leading)
        Spacer(minLength: 0)
      }
    case .paused:
      Label(
        "The bots are waiting for you. Your next message lets them continue.",
        systemImage: "pause.circle"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
    }
  }
}

/// A bot's message in a group: who wrote it, its text and source links, and the reactions it got.
struct GroupBotMessage: View {
  @Environment(AppModel.self) private var model
  let message: Message
  var reactions: [Reaction.Mark] = []

  private var sender: Agent? { model.agents.first { $0.id == message.origin?.agentId } }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      avatar
      VStack(alignment: .leading, spacing: 4) {
        Text(message.origin?.name ?? sender?.name ?? "A bot")
          .font(.caption.weight(.medium))
          .foregroundStyle(sender?.avatar.bodyColor ?? .secondary)
        bubble
      }
      Button("Reply", systemImage: "arrowshape.turn.up.left") { model.replyTo = message }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.top, 20)
      Spacer(minLength: 24)
    }
  }

  @ViewBuilder private var avatar: some View {
    if let sender {
      BotAvatarView(agent: sender, size: 28, state: .idle).accessibilityHidden(true)
    } else {
      Image(systemName: "person.crop.circle").font(.system(size: 24)).foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
    }
  }

  private var bubble: some View {
    let reply = SourceCitations.split(message.text, sources: message.sources ?? [])
    return VStack(alignment: .leading, spacing: 6) {
      MarkdownText(text: reply.text).textSelection(.enabled)
      ForEach(reply.chips, id: \.href) { chip in
        if let url = URL(string: chip.href) {
          Link(destination: url) {
            Label(chip.title.nilIfEmpty ?? chip.href, systemImage: "link")
              .font(.callout).lineLimit(1)
          }
        }
      }
    }
    .bubble(owner: false)
    .fixedSize(horizontal: false, vertical: true)
    .overlay(alignment: .bottomTrailing) {
      if !reactions.isEmpty {
        ReactionBadge(reactions: reactions.map(\.emoji)).offset(x: 8, y: 16)
      }
    }
    .padding(.bottom, reactions.isEmpty ? 0 : 14)
    .contextMenu {
      Button("Reply") { model.replyTo = message }
      Button("Copy") { UIPasteboard.general.string = message.text }
    }
  }
}

/// Emoji a bot reacted with instead of replying, pinned to the corner of the message it answers.
struct ReactionBadge: View {
  let reactions: [String]

  var body: some View {
    Text(reactions.joined(separator: " "))
      .font(.callout)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .glassEffect(.regular, in: .capsule)
      .accessibilityLabel("Reacted \(reactions.joined(separator: " "))")
  }
}

/// Creates or edits a group: its name and two to six member bots.
struct GroupEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: GroupDraft
  @State private var confirmingDelete = false

  var body: some View {
    NavigationStack {
      form
        .formStyle(.grouped)
        .navigationTitle(draft.groupID == nil ? "New Group Chat" : "Edit Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              model.errorText = ""
              model.groupDraft = nil
              dismiss()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(draft.groupID == nil ? "Create" : "Save") { model.saveGroup(draft) }
              .disabled(!draft.isValid)
          }
        }
        .confirmsGroupDeletion(name: draft.name, isPresented: $confirmingDelete) {
          guard let id = draft.groupID else { return }
          model.groupDraft = nil
          model.deleteGroup(id)
          dismiss()
        }
    }
  }

  private var form: some View {
    Form {
      SheetError()
      Section("Name") {
        TextField("Name", text: $draft.name)
          .onChange(of: draft.name) { _, name in
            if name.count > GroupDraft.nameLimit {
              draft.name = String(name.prefix(GroupDraft.nameLimit))
            }
          }
      }
      membersSection
      if draft.groupID != nil {
        Section {
          Button("Delete Group…", role: .destructive) { confirmingDelete = true }
        }
      }
    }
  }

  private var membersSection: some View {
    Section {
      ForEach(model.agents) { agent in
        Toggle(
          isOn: Binding(
            get: { draft.includes(agent.id) },
            set: { draft.setMember(agent.id, included: $0) })
        ) {
          HStack(spacing: 8) {
            BotAvatarView(agent: agent, size: 28, state: .idle).accessibilityHidden(true)
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
  }
}
