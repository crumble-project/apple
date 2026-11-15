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
    @State private var width: CGFloat = 0
    /// Avatars draw on the CPU every frame, so the header's comes alive only while the pointer is in the chat.
    @State private var pointerInside = false
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
        // The chat switch crossfades; its scroll position must not animate, or it slides up from the top.
        .transaction { $0.animation = nil }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .jumpToLatest()
        .chatAttention(.bot(agent.id), ready: model.snapshot != nil)
        .headerBand {
            ChatHeader(title: agent.name, help: detailsShown ? "Hide Details" : "Show Details", action: showDetails) {
                let state = model.botState(agent)
                CalmAvatar(agent: agent, size: 62, state: state, active: pointerInside)
            }
        }
        .overlay {
            if rows.isEmpty { EmptyChatView(agent: agent) }
        }
        .onHover { pointerInside = $0 }
        .task(id: model.jobPollDelay) { await model.watchJobs() }
        .task(id: model.heldActionBoard.needsPolling) { await model.watchHeldActions() }
        .task(id: model.botRequestBoard.needsPolling) { await model.watchBotRequests() }
        .task(id: model.callRequestBoard.needsPolling) { await model.watchCallRequests() }
        .task(id: model.botSecretBoard.needsPolling) { await model.watchBotSecrets() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Present while the chat loads, so nothing shifts when it arrives; sending waits for it.
            Composer(target: .chat(agent, model: model), ready: model.snapshot != nil)
        }
        .navigationTitle(agent.name)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            // With the title removed nothing pushes the button to the trailing edge.
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button(panelTitle, systemImage: panelShown ? "xmark" : "sidebar.trailing") { togglePanel() }
                    .help(panelTitle)
            }
        }
        .safeAreaInset(edge: .trailing, spacing: 0) { rightPanel }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension ChatView {
    /// A job takes the details' place, as on the web, and the button brings them back.
    @ViewBuilder fileprivate var rightPanel: some View {
        if let job = model.jobHistory {
            panelColumn(width: min(JobSheet.panelWidth, width / 2)) { JobSheet(job: job, inPanel: true) }
        } else if let call = model.openCall {
            panelColumn(width: min(JobSheet.panelWidth, width / 2)) { CallSheet(call: call, botName: agent.name) }
        } else if showsDetails {
            panelColumn(width: DetailsPanel.width) {
                DetailsPanel(agent: agent)
            }
        }
    }

    private func panelColumn(width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        // The panel's color and edge run up under the toolbar so its close button sits on the panel.
        content()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background { Palette.chrome.ignoresSafeArea() }
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.hairline).frame(width: 1).ignoresSafeArea()
            }
    }

    fileprivate var detailsShown: Bool { showsDetails && model.jobHistory == nil && model.openCall == nil }
    fileprivate var panelShown: Bool { showsDetails || model.jobHistory != nil || model.openCall != nil }

    fileprivate var panelTitle: String {
        if model.openCall != nil { return "Close Call" }
        if model.jobHistory != nil { return "Close Job" }
        return showsDetails ? "Hide Details" : "Show Details"
    }

    /// The toolbar's button closes whatever the panel shows; a closed call or job gives the column
    /// back to the details if they were showing.
    fileprivate func togglePanel() {
        if model.openCall != nil {
            model.closeCall()
        } else if model.jobHistory != nil {
            model.closeJob()
        } else {
            showsDetails.toggle()
        }
    }

    fileprivate func showDetails() {
        guard model.jobHistory == nil, model.openCall == nil else {
            model.closeJob()
            model.closeCall()
            showsDetails = true
            return
        }
        showsDetails.toggle()
    }
}

struct EmptyChatView: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var slow = false

    var body: some View {
        if model.snapshot == nil {
            // A quick load shouldn't flash a spinner; only one that takes a moment shows it.
            ProgressView()
                .opacity(slow ? 1 : 0)
                .task {
                    try? await Task.sleep(for: .milliseconds(400))
                    slow = true
                }
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
    let agent: Agent
    let row: ChatRow

    var body: some View {
        switch row {
        case .older:
            if model.loadingOlder {
                ProgressView().controlSize(.small)
            } else {
                Button("Load Earlier Messages") { model.loadOlder() }
                    .disabled(model.snapshot == nil)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        case .time(_, let label):
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .message(let message, let reactions):
            MessageView(message: message, reactions: reactions, botName: agent.name)
        case .thinking:
            let label = (model.snapshot?.working ?? .thinking).label + "…"
            HStack(spacing: 10) {
                TypingDots()
                    .padding(.horizontal, 15)
                    .padding(.vertical, 14)
                    .background(Palette.bubble, in: .rect(cornerRadius: 16))
                Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        case .failure(let error):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The agent couldn’t finish").font(.system(size: 14, weight: .medium))
                    Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                    if let url = model.client?.webSettingsURL(.providers) {
                        Link("Provider Settings…", destination: url)
                            .padding(.top, 4)
                    }
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
