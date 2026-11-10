import apfelkern
import BotAvatar
import SwiftUI
import UIKit

struct MessageView: View {
  @Environment(AppModel.self) private var model
  let message: Message
  var reactions: [String] = []
  var place = BubblePlace()
  var botName = ""

  private var replyable: Bool {
    !(message.entryId ?? "").isEmpty && (message.role == "user" || message.role == "assistant")
  }
  private var outsideCall: CallRequest? {
    callRequest(for: message, in: model.callRequestBoard.requests).flatMap {
      $0.status == .declined ? nil : $0
    }
  }
  private func noticeDetail(_ request: CallRequest) -> String {
    let detail = callNoticeDetail(message, request: request)
    return detail.prefix(1).uppercased() + detail.dropFirst()
  }
  private var owner: Bool { message.origin == nil || message.origin?.kind == "owner" }

  var body: some View {
    switch message.role {
    case "event":
      if message.kind == "bot-message" {
        BotMessageView(message: message)
      } else if message.kind == JobQuestionEvent.messageKind, let question = message.jobQuestion {
        HStack {
          JobQuestionCard(question: question, text: message.text)
          Spacer(minLength: 24)
        }
      } else if message.kind == HeldActionEvent.messageKind, let held = message.heldAction {
        HStack {
          HeldActionCard(held: held, title: message.text)
          Spacer(minLength: 24)
        }
      } else if let failure = JobFailure(message: message) {
        HStack {
          JobFailureCard(failure: failure) { model.openJob(failure.kind, failure.name) }
          Spacer(minLength: 24)
        }
      } else if let call = CallMarker(message: message) {
        CallMarkerView(marker: call, botName: botName)
      } else {
        EventView(message: message)
      }
    case "toolResult":
      if let component = DisplayComponent(message: message) {
        DisplayView(component: component).frame(maxWidth: .infinity, alignment: .leading)
      } else if message.isDesktopScreenshot {
        HStack {
          DesktopScreenshotCard(message: message)
          Spacer(minLength: 24)
        }
      } else if let job = Job(message: message) {
        HStack {
          JobCard(job: model.job(job))
          Spacer(minLength: 24)
        }
      } else if let request = BotRequest(message: message) {
        HStack {
          BotRequestCard(request: request)
          Spacer(minLength: 24)
        }
      } else if let request = CallRequest(message: message) {
        HStack {
          CallRequestCard(request: request)
          Spacer(minLength: 24)
        }
      } else if let ask = BotSecretAsk(message: message) {
        HStack {
          BotSecretRequestCard(ask: ask)
          Spacer(minLength: 24)
        }
      }
    case "user":
      if let request = outsideCall {
        HStack {
          CallRequestRow(request: request, detail: noticeDetail(request), opens: true)
          Spacer(minLength: 24)
        }
      } else if let call = CallMarker(message: message) {
        CallMarkerView(marker: call, botName: botName, reactions: reactions)
      } else if let notice = noticeTitle(message) {
        EventView(message: message, title: notice)
      } else {
        HStack(spacing: 0) {
          Spacer(minLength: 56)
          ViewThatFits(in: .horizontal) {
            sentMessageContent.fixedSize(horizontal: true, vertical: false)
            sentMessageContent.frame(maxWidth: 520, alignment: .trailing)
          }
        }
        .swipeToReply(enabled: replyable) { model.replyTo = message }
      }
    default:
      HStack(spacing: 0) {
        ViewThatFits(in: .horizontal) {
          incomingMessageContent.fixedSize(horizontal: true, vertical: false)
          incomingMessageContent
            .frame(maxWidth: 560, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        Spacer(minLength: 44)
      }
      .swipeToReply(enabled: replyable) { model.replyTo = message }
    }
  }

  @ViewBuilder private var sentMessageContent: some View {
    VStack(alignment: .trailing, spacing: 4) {
      if !owner {
        Text(messageLabel(message)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
      }
      ReplyQuote(message: message)
      SentAttachments(message: message)
      if !message.text.isEmpty {
        Text(message.text)
          .textSelection(.enabled)
          .bubble(owner: owner, tail: place.endsRun)
          .contextMenu { menu }
          .overlay(alignment: .topLeading) {
            if !reactions.isEmpty { ReactionBadge(reactions: reactions).offset(x: -8, y: -14) }
          }
          .padding(.top, reactions.isEmpty ? 0 : 14)
      }
      deliveryStatus
      if let via = message.origin?.via { GatewayOriginLabel(id: via) }
    }
  }

  @ViewBuilder private var deliveryStatus: some View {
    if message.deliveryState != .confirmed {
      HStack(spacing: 5) {
        if message.deliveryState == .sending {
          ProgressView().controlSize(.mini)
          Text("Sending…")
        } else {
          Text("Not sent")
          Button("Retry") { model.retryMessage(message) }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
        }
      }
      .font(.caption)
      .foregroundStyle(message.deliveryState == .failed ? .red : .secondary)
    }
  }

  private var incomingMessageContent: some View {
    let reply = SourceCitations.split(message.text, sources: message.sources ?? [])
    return VStack(alignment: .leading, spacing: 6) {
      MarkdownText(text: reply.text).textSelection(.enabled)
      ForEach(reply.chips, id: \.href) { SourceChipLink(chip: $0) }
    }
    .bubble(owner: false, tail: place.endsRun)
    .contextMenu { menu }
  }

  @ViewBuilder private var menu: some View {
    if replyable {
      Button("Reply", systemImage: "arrowshape.turn.up.left") { model.replyTo = message }
    }
    Button("Copy", systemImage: "doc.on.doc") {
      UIPasteboard.general.string = message.text
    }
  }
}

struct BotMessageView: View {
  let message: Message
  @State private var expanded = false

  private var expansionButton: some View {
    Button {
      expanded.toggle()
    } label: {
      HStack(spacing: 12) {
        Rectangle().fill(.quaternary).frame(height: 1)
        HStack(spacing: 5) {
          Text("Bot communication: \(sender) → \(recipient)")
            .lineLimit(1)
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.medium))
        }
        .layoutPriority(1)
        Rectangle().fill(.quaternary).frame(height: 1)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Bot communication: \(sender) → \(recipient)")
    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
  }

  private var communication: BotCommunication? { message.communication }
  private var sender: String { communication?.fromName.nilIfEmpty ?? "Unknown bot" }
  private var recipient: String { communication?.toName.nilIfEmpty ?? "Unknown bot" }
  private var status: String {
    switch communication?.status {
    case "done": "Reply"
    case "failed": "Failed"
    case "cancelled": "Cancelled"
    default: "Sent"
    }
  }
  private var statusColor: Color {
    switch communication?.status {
    case "failed", "cancelled": .red
    case "done": .green
    default: .secondary
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      expansionButton
      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          Text(status)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
          MarkdownText(text: message.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 560, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

struct EventView: View {
  @Environment(AppModel.self) private var model
  let message: Message
  var title: String?

  var body: some View {
    @Bindable var model = model
    let open = Binding(
      get: { model.expanded.contains(message.id) },
      set: {
        if $0 { model.expanded.insert(message.id) } else { model.expanded.remove(message.id) }
      }
    )
    DisclosureGroup(
      title ?? (message.kind == "reset" ? "Context reset" : "Earlier messages summarized"),
      isExpanded: open
    ) {
      MarkdownText(text: message.text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
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
      let quoted =
        message.replyPreview?.nilIfEmpty ?? model.messages.first { $0.entryId == reply }?.text ?? ""
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
