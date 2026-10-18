import apfelkern
import AppKit
import SwiftUI

struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @State private var hovered = false

    private var replyable: Bool {
        !(message.entryId ?? "").isEmpty && (message.role == "user" || message.role == "assistant")
    }
    private var owner: Bool { message.origin == nil || message.origin?.kind == "owner" }

    var body: some View {
        switch message.role {
        case "event":
            if message.kind == "bot-message" {
                BotMessageView(message: message)
            } else {
                EventView(message: message)
            }
        case "user":
            HStack(spacing: 6) {
                Spacer(minLength: 60)
                replyButton
                ViewThatFits(in: .horizontal) {
                    sentMessageContent.fixedSize(horizontal: true, vertical: false)
                    sentMessageContent.frame(maxWidth: 520, alignment: .trailing)
                }
            }
            .onHover { hovered = $0 }
        default:
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    incomingMessageContent.fixedSize(horizontal: true, vertical: false)
                    incomingMessageContent
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                replyButton
                Spacer(minLength: 60)
            }
            .onHover { hovered = $0 }
        }
    }

    @ViewBuilder private var sentMessageContent: some View {
        VStack(alignment: .trailing, spacing: 4) {
            originLabel
            ReplyQuote(message: message)
            SentAttachments(message: message)
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .bubble(owner: owner)
                    .contextMenu { menu }
            }
            if message.deliveryState != .confirmed {
                HStack(spacing: 5) {
                    if message.deliveryState == .sending {
                        ProgressView().controlSize(.mini)
                        Text("Sending…")
                    } else {
                        Text("Not sent")
                        Button("Retry") { model.retryMessage(message) }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(message.deliveryState == .failed ? .red : .secondary)
            }
        }
    }

    @ViewBuilder private var originLabel: some View {
        if !owner {
            if message.origin?.kind == "bot" {
                Label(messageLabel(message), systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            } else {
                Text(messageLabel(message)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder private var incomingMessageContent: some View {
        MarkdownText(text: message.text)
            .textSelection(.enabled)
            .bubble(owner: false)
            .contextMenu { menu }
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

struct BotMessageView: View {
    let message: Message
    @State private var expanded = false

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
            expandedContent
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var expandedContent: some View {
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
