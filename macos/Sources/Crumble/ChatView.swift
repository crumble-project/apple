import SwiftUI

/// One row of the chat list: a transcript message or a transient row around it.
enum ChatRow: Identifiable {
    case older
    case time(String, String)
    case message(Message)
    case thinking
    case failure(String)

    var id: String {
        switch self {
        case .older: "older"
        case .time(let id, _): "time:" + id
        case .message(let message): message.id
        case .thinking: "thinking"
        case .failure: "error"
        }
    }

    static func rows(messages: [Message], snapshot: ChatSnapshot?, hasMore: Bool) -> [ChatRow] {
        var rows: [ChatRow] = hasMore ? [.older] : []
        var last: Int64 = 0
        for message in messages where shownInChat(message) {
            if let timestamp = message.timestamp, timestamp > 0 {
                if timestamp - last > 30 * 60 * 1000 {
                    rows.append(.time(message.id, timeLabel(Date(timeIntervalSince1970: Double(timestamp) / 1000))))
                }
                last = timestamp
            }
            rows.append(.message(message))
        }
        if let snapshot {
            if snapshot.isRunning {
                rows.append(.thinking)
            }
            if let error = snapshot.error, !error.isEmpty { rows.append(.failure(error)) }
        }
        return rows
    }

    /// Keeps the conversation itself: owner and agent text and context events, not thinking,
    /// tool calls, or tool results.
    static func shownInChat(_ message: Message) -> Bool {
        switch message.role {
        case "user":
            return !message.text.isEmpty || !(message.attachments ?? []).isEmpty
        case "event":
            return !message.text.isEmpty
        case "assistant":
            guard case .array(let blocks)? = message.blocks else { return !contentText(message.blocks).isEmpty }
            return blocks.contains {
                $0["type"]?.stringValue == "text"
                    && !($0["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        default:
            return false
        }
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        let rows = ChatRow.rows(messages: model.messages, snapshot: model.snapshot, hasMore: model.hasMore)
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(rows) { row in
                    ChatRowView(agent: agent, row: row)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if rows.isEmpty { EmptyChatView(agent: agent) }
        }
        .safeAreaInset(edge: .bottom) {
            if model.snapshot != nil { Composer(agent: agent) }
        }
        .navigationTitle(agent.name)
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    model.openEditor()
                } label: {
                    headerTitle
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(agent.name) profile")
                .accessibilityHint("Shows the agent profile")
                .accessibilityValue(subtitle)
                .help("Agent Profile")
            }
            .sharedBackgroundVisibility(.visible)
        }
    }

    private var subtitle: String {
        if !agent.enabled { return "Paused" }
        if model.snapshot?.isRunning == true { return "Working…" }
        return agent.description?.nilIfEmpty ?? agent.model ?? ""
    }

    @ViewBuilder private var headerTitle: some View {
        HStack(spacing: 8) {
            BotAvatarView(agent: agent, size: 28, state: model.botState(agent), live: true)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 40, maxWidth: 320, minHeight: 40)
        .contentShape(Rectangle())
    }
}

struct EmptyChatView: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        if model.snapshot == nil {
            ProgressView()
        } else {
            VStack(spacing: 10) {
                BotAvatarView(agent: agent, size: 96, state: model.botState(agent), live: true)
                Text(agent.name).font(.title2.bold())
                Text(
                    agent.description?.nilIfEmpty
                        ?? "Send a message to start. Your agent keeps its work and memory between visits."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
            .padding(.bottom, 60)
        }
    }
}

struct ChatRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let agent: Agent
    let row: ChatRow

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
        case .message(let message):
            MessageView(message: message)
        case .thinking:
            HStack(spacing: 8) {
                BotAvatarView(agent: agent, size: 24, state: .working, live: true)
                Text("Working…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working…")
        case .failure(let error):
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The agent couldn’t finish").font(.headline)
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Button("Provider Settings…") { openSettings() }
                }
                .padding(14)
                .background(.red.opacity(0.08), in: .rect(cornerRadius: 12))
                .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }
}
