import SwiftUI

/// One row of the chat list: a transcript message or a transient row around it.
enum ChatRow: Identifiable {
    case older
    case time(String, String)
    case message(Message)
    case partial(String)
    case thinking
    case failure(String)

    var id: String {
        switch self {
        case .older: "older"
        case .time(let id, _): "time:" + id
        case .message(let message): message.id
        case .partial: "partial"
        case .thinking: "thinking"
        case .failure: "error"
        }
    }

    static func rows(messages: [Message], snapshot: ChatSnapshot?, hasMore: Bool) -> [ChatRow] {
        var rows: [ChatRow] = hasMore ? [.older] : []
        var last: Int64 = 0
        for message in messages where shownInChat(message) {
            if let at = message.timestamp, at > 0 {
                if at - last > 30 * 60 * 1000 {
                    rows.append(.time(message.id, timeLabel(Date(timeIntervalSince1970: Double(at) / 1000))))
                }
                last = at
            }
            rows.append(.message(message))
        }
        if let snapshot {
            if let partial = snapshot.partial, !partial.isEmpty {
                rows.append(.partial(partial))
            } else if snapshot.isRunning {
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
        case "user", "event":
            return !message.text.isEmpty
        case "assistant":
            guard case .array(let blocks)? = message.blocks else { return !contentText(message.blocks).isEmpty }
            return blocks.contains { $0["type"]?.stringValue == "text" && !($0["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BotAvatarView(agent: agent, size: 28, state: model.botState(agent), live: true)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Summarize Older Context", systemImage: "rectangle.compress.vertical") { model.compactChat() }
                    .disabled(model.loading || model.messages.isEmpty)
                Button("Agent Profile", systemImage: "person.crop.circle") { model.openEditor() }
            }
        }
    }

    private var subtitle: String {
        if !agent.enabled { return "Paused" }
        if model.snapshot?.isRunning == true { return "Working…" }
        return agent.description?.nilIfEmpty ?? agent.model ?? ""
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
                Text(agent.description?.nilIfEmpty ?? "Send a message to start. Your agent keeps its work and memory between visits.")
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
        case .partial(let text):
            HStack {
                MarkdownText(text: text).bubble(owner: false)
                Spacer(minLength: 60)
            }
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(agent.name) is working…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
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

struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @State private var hovered = false

    private var replyable: Bool { !(message.entryId ?? "").isEmpty && (message.role == "user" || message.role == "assistant") }
    private var owner: Bool { message.origin == nil || message.origin?.kind == "owner" }

    var body: some View {
        switch message.role {
        case "event":
            EventView(message: message)
        case "user":
            HStack(spacing: 6) {
                Spacer(minLength: 60)
                replyButton
                VStack(alignment: .trailing, spacing: 4) {
                    if !owner {
                        Text(messageLabel(message)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                    }
                    ReplyQuote(message: message)
                    Text(message.text)
                        .textSelection(.enabled)
                        .bubble(owner: owner)
                        .contextMenu { menu }
                }
                .frame(maxWidth: 520, alignment: .trailing)
            }
            .onHover { hovered = $0 }
        default:
            HStack(spacing: 6) {
                MarkdownText(text: message.text)
                    .textSelection(.enabled)
                    .bubble(owner: false)
                    .frame(maxWidth: 560, alignment: .leading)
                    .contextMenu { menu }
                replyButton
                Spacer(minLength: 60)
            }
            .onHover { hovered = $0 }
        }
    }

    @ViewBuilder private var replyButton: some View {
        if replyable {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { model.replyTo = message }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovered ? 1 : 0)
                .help("Reply")
        }
    }

    @ViewBuilder private var menu: some View {
        if replyable {
            Button("Reply") { model.replyTo = message }
        }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        }
    }
}

struct EventView: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        @Bindable var model = model
        let open = Binding(
            get: { model.expanded.contains(message.id) },
            set: { if $0 { model.expanded.insert(message.id) } else { model.expanded.remove(message.id) } }
        )
        DisclosureGroup(message.kind == "reset" ? "Context reset" : "Earlier messages summarized", isExpanded: open) {
            Text(message.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .font(.callout)
        .frame(maxWidth: 560)
    }
}

struct ReplyQuote: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        if let reply = message.replyTo, !reply.isEmpty {
            let quoted = message.replyPreview?.nilIfEmpty ?? model.messages.first { $0.entryId == reply }?.text ?? ""
            if !quoted.isEmpty {
                HStack(spacing: 8) {
                    Capsule().fill(.tint).frame(width: 2)
                    Text(preview(quoted)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
            }
        }
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let running = model.snapshot?.isRunning == true
        VStack(spacing: 6) {
            if let reply = model.replyTo {
                HStack(spacing: 8) {
                    Capsule().fill(.tint).frame(width: 2, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to " + messageLabel(reply)).font(.caption.bold()).foregroundStyle(.tint)
                        Text(preview(reply.text)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel Reply", systemImage: "xmark") { model.replyTo = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(agent.enabled ? "Message \(agent.name)" : "\(agent.name) is paused. Enable it in its profile.",
                          text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(model.sending || !agent.enabled)
                    .padding(.vertical, 7)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        model.sendMessage()
                        return .handled
                    }
                if running {
                    Button("Stop", systemImage: "stop.fill") { model.abortChat() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                } else if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.sending {
                    Button("Send", systemImage: "arrow.up") { model.sendMessage() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .frame(minHeight: 40)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .onAppear { focused = true }
    }
}

extension View {
    /// The bubble a message sits in: the accent color for the owner, a quiet gray otherwise.
    func bubble(owner: Bool) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(owner ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(owner ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.07)), in: .rect(cornerRadius: 18))
    }
}

func messageLabel(_ message: Message) -> String {
    if message.role == "assistant" { return "Agent" }
    if message.role != "user" { return "Tool result" }
    if message.origin?.kind == "task" { return "Task · " + (message.origin?.name ?? "") }
    if message.origin?.kind == "bot" { return "From " + (message.origin?.name ?? "") }
    return "You"
}

func preview(_ text: String) -> String {
    var plain = text
    for mark in ["**", "__", "`", "# ", "> "] { plain = plain.replacingOccurrences(of: mark, with: "") }
    plain = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return plain.count > 120 ? String(plain.prefix(119)) + "…" : plain
}
