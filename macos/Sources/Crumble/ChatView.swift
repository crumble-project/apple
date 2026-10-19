import apfelkern
import BotAvatar
import SwiftUI

/// One row of the chat list: a transcript message or a transient row around it.
enum ChatRow: Identifiable {
    case older
    case time(String, String)
    case message(Message, reactions: [String])
    case thinking
    case failure(String)

    var id: String {
        switch self {
        case .older: "older"
        case .time(let id, _): "time:" + id
        case .message(let message, _): message.id
        case .thinking: "thinking"
        case .failure: "error"
        }
    }

    static func rows(messages: [Message], snapshot: ChatSnapshot?, hasMore: Bool) -> [ChatRow] {
        var rows: [ChatRow] = hasMore ? [.older] : []
        var last: Int64 = 0
        let reactions = Reaction.byMessage(messages)
        for message in messages where shownInChat(message) {
            if let timestamp = message.timestamp, timestamp > 0 {
                if timestamp - last > 30 * 60 * 1000 {
                    rows.append(.time(message.id, timeLabel(Date(timeIntervalSince1970: Double(timestamp) / 1000))))
                }
                last = timestamp
            }
            rows.append(.message(message, reactions: reactions[message.id] ?? []))
        }
        if let snapshot {
            if snapshot.isRunning {
                rows.append(.thinking)
            }
            if let error = snapshot.error, !error.isEmpty { rows.append(.failure(error)) }
        }
        return rows
    }

    /// Keeps the conversation itself: owner and agent text, context events, and visuals the agent
    /// showed, not thinking, tool calls, or other tool results.
    static func shownInChat(_ message: Message) -> Bool {
        switch message.role {
        case "toolResult":
            return DisplayComponent(message: message) != nil || CodingJob(message: message) != nil
        case "user":
            // A coding job's report is behind its card; the bot relays what matters.
            guard message.origin?.kind != CodingJob.originKind else { return false }
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

extension ChatRow {
    /// Space above a row: tight between messages from the same side, roomier around times.
    static func gap(after previous: ChatRow?, before row: ChatRow) -> CGFloat {
        guard let previous else { return 0 }
        switch (previous, row) {
        case (_, .time): return 22
        case (.time, _): return 12
        case (.message(let above, _), .message(let below, _))
        where above.role == below.role && (above.role == "user" || above.role == "assistant"):
            return 6
        default: return 14
        }
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showsDetails") private var showsDetails = true
    let agent: Agent

    var body: some View {
        let rows = ChatRow.rows(messages: model.messages, snapshot: model.snapshot, hasMore: model.hasMore)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ChatRowView(agent: agent, row: row)
                        .padding(.top, ChatRow.gap(after: index > 0 ? rows[index - 1] : nil, before: row))
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
            if rows.isEmpty { EmptyChatView(agent: agent) }
        }
        .background(alignment: .top) {
            DitherGlow(color: agent.color).frame(height: 150).ignoresSafeArea(edges: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.snapshot != nil { Composer(agent: agent) }
        }
        .navigationTitle(agent.name)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            // With the title removed nothing pushes the button to the trailing edge.
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsDetails.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help(showsDetails ? "Hide Details" : "Show Details")
            }
        }
        .inspector(isPresented: $showsDetails) {
            DetailsPanel(agent: agent)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
    }
}

struct EmptyChatView: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        if model.snapshot == nil {
            ProgressView()
        } else {
            VStack(spacing: 4) {
                Text("Say hello to \(agent.name)").font(.system(size: 15, weight: .medium))
                Text(
                    agent.description?.nilIfEmpty
                        ?? "It keeps its memory and work between visits."
                )
                .font(.system(size: 13))
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
    @Environment(\.openWindow) private var openWindow
    let agent: Agent
    let row: ChatRow

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
            MessageView(message: message, reactions: reactions)
        case .thinking:
            HStack {
                TypingDots()
                    .padding(.horizontal, 15)
                    .padding(.vertical, 14)
                    .background(Palette.bubble, in: .rect(cornerRadius: 18))
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working…")
        case .failure(let error):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The agent couldn’t finish").font(.system(size: 14, weight: .medium))
                    Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                    Button("Provider Settings…") { openWindow(id: SettingsButton.windowID) }.padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.red.opacity(0.06), in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.red.opacity(0.2)))
                .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Three dots that rise in turn while a bot works on a reply.
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (time / 1.2 * 3 - Double(index) * 0.45).truncatingRemainder(dividingBy: 3)
                    let lift = phase >= 0 && phase < 1 ? sin(phase * .pi) : 0
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(reduceMotion ? 0.6 : 0.35 + 0.65 * lift)
                }
            }
        }
    }
}
