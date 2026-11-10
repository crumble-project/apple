import apfelkern
import BotAvatar
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One row of the chat list: a transcript message or a transient row around it.
enum ChatRow: Identifiable {
  case older
  case time(String, String)
  case message(Message, reactions: [String])
  case partial(String)
  case thinking
  case failure(String)

  var id: String {
    switch self {
    case .older: "older"
    case .time(let id, _): "time:" + id
    case .message(let message, _): message.id
    case .partial: "partial"
    case .thinking: "thinking"
    case .failure: "error"
    }
  }

  static func rows(messages: [Message], snapshot: ChatSnapshot?, hasMore: Bool) -> [ChatRow] {
    var rows: [ChatRow] = hasMore ? [.older] : []
    var last: Int64 = 0
    let reactions = Reaction.byMessage(messages)
    let sources = SourceCitations.byReply(messages)
    for var message in messages where shownInChat(message) {
      if let timestamp = message.timestamp, timestamp > 0 {
        if timestamp - last > 30 * 60 * 1000 {
          rows.append(.time(message.id, timeLabel(Date(timeIntervalSince1970: Double(timestamp) / 1000))))
        }
        last = timestamp
      }
      message.sources = sources[message.id]
      rows.append(.message(message, reactions: reactions[message.id] ?? []))
    }
    if let snapshot {
      // Live generation text is intentionally withheld until the completed assistant
      // message arrives in the transcript. Keep the typing indicator while it runs.
      if snapshot.isRunning { rows.append(.thinking) }
      if let error = snapshot.error, !error.isEmpty { rows.append(.failure(error)) }
    }
    return rows
  }
}

extension ChatRow {
  /// Who a bubble is from, so messages in a row from one sender read as a run.
  var bubbleSender: String? {
    guard case .message(let message, _) = self else { return nil }
    if message.role == "assistant" { return "bot" }
    return message.role == "user" && noticeTitle(message) == nil ? "owner" : nil
  }
}

struct ChatView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var showsDetails = false
  @State private var afterDetails: (() -> Void)?
  let agent: Agent

  var body: some View {
    let rows = ChatRow.rows(
      messages: model.messages, snapshot: model.snapshot, hasMore: model.hasMore)
    let places = BubblePlace.places(rows, sender: \.bubbleSender)
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(zip(rows, places)), id: \.0.id) { row, place in
          ChatRowView(agent: agent, row: row, place: place).padding(.top, place.gap)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 12)
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .jumpToLatest()
    .keepsContentSwipe()
    .overlay {
      if rows.isEmpty { EmptyChatView(agent: agent) }
    }
    .task(id: model.jobPollDelay) { await model.watchJobs() }
    .task(id: model.heldActionBoard.needsPolling) { await model.watchHeldActions() }
    .task(id: model.botRequestBoard.needsPolling) { await model.watchBotRequests() }
    .task(id: model.botSecretBoard.needsPolling) { await model.watchBotSecrets() }
    .safeAreaInset(edge: .bottom) {
      if model.snapshot != nil { Composer(target: .chat(agent, model: model)) }
    }
    .navigationTitle(agent.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) { profileButton }
      .sharedBackgroundVisibility(.hidden)
      if sizeClass != .compact {
        if agent.tools?.contains(DesktopJob.toolName) == true {
          ToolbarItem(placement: .primaryAction) {
            Button("Bot Desktop", systemImage: "display") {
              model.botDesktop = BotDesktopTarget(id: agent.id)
            }
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Details", systemImage: "sidebar.trailing") { showsDetails.toggle() }
            .help(showsDetails ? "Hide Details" : "Show Details")
        }
      }
    }
    // A phone gets a sheet with its own stack for the top bar; an inspector inside the chat's stack can't hold one.
    .inspector(isPresented: sizeClass == .compact ? .constant(false) : $showsDetails) {
      // Built even while hidden, so on a phone its toolbar would land in the chat's bar.
      if sizeClass != .compact {
        details.inspectorColumnWidth(min: 260, ideal: 300, max: 400)
      }
    }
    .sheet(isPresented: sizeClass == .compact ? $showsDetails : .constant(false)) {
      NavigationStack { details }
    }
  }

  private var details: some View {
    DetailsPanel(agent: agent, leave: leaveDetails) { showsDetails = false }
      .onDisappear {
        afterDetails?()
        afterDetails = nil
      }
  }

  /// The bot's portrait over its name, as Messages heads a conversation. Tapping opens its details.
  private var profileButton: some View {
    Button {
      showsDetails = true
    } label: {
      VStack(spacing: -6) {
        BotAvatarView(agent: agent, size: 48, state: model.botState(agent), live: true)
        HStack(spacing: 3) {
          Text(agent.name).font(.subheadline.weight(.semibold)).lineLimit(1)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open \(agent.name) details")
    .accessibilityValue(subtitle)
  }

  /// On a phone the panel is a sheet, and the app's sheets can't open over it until it has gone.
  private func leaveDetails(_ action: @escaping () -> Void) {
    guard sizeClass == .compact else { return action() }
    afterDetails = action
    showsDetails = false
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
  let agent: Agent
  let row: ChatRow
  var place = BubblePlace()

  var body: some View {
    switch row {
    case .older:
      if model.loadingOlder {
        ProgressView().controlSize(.small)
      } else {
        Button("Load Earlier Messages") { model.loadOlder() }
      }
    case .time(_, let label):
      ChatTimeLabel(text: label)
    case .message(let message, let reactions):
      MessageView(message: message, reactions: reactions, place: place, botName: agent.name)
    case .partial(let text):
      HStack {
        MarkdownText(text: text).bubble(owner: false)
        Spacer(minLength: 44)
      }
    case .thinking:
      HStack(spacing: 8) {
        TypingBubble()
        Text(Working(snapshot: model.snapshot, messages: model.messages).label + "…")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
    case .failure(let error):
      ChatFailureRow(title: "The agent couldn’t finish", error: error) { model.openProviderSettings() }
    }
  }
}

/// The centered time above a stretch of conversation.
struct ChatTimeLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .padding(.top, 8)
  }
}

/// A failed turn, as quiet as Messages' "Not Delivered".
struct ChatFailureRow: View {
  let title: String
  let error: String
  var openSettings: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.medium)
        Text(error).foregroundStyle(.secondary).textSelection(.enabled)
        if let openSettings {
          Button("Provider Settings…", action: openSettings).buttonStyle(.borderless)
        }
      }
      Spacer(minLength: 44)
    }
    .font(.footnote)
    .padding(.leading, BubbleShape.tailWidth + 6)
  }
}
