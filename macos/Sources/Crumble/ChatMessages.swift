import apfelkern
import AppKit
import SwiftUI

struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    var reactions: [String] = []
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
            // Without a width cap, bubbles hug their text and the actions sit right beside them; the
            // spacer keeps long ones clear of the other side.
            HStack(alignment: .center, spacing: 6) {
                Spacer(minLength: 56)
                actions
                sentMessageContent
            }
            .onHover { hovered = $0 }
        case "toolResult":
            if let component = DisplayComponent(message: message) {
                HStack {
                    DisplayView(component: component)
                    Spacer(minLength: 56)
                }
            } else if let job = Job(message: message) {
                HStack {
                    JobCard(job: model.job(job))
                    Spacer(minLength: 56)
                }
            }
        default:
            receivedMessage
        }
    }

    private var receivedMessage: some View {
        HStack(alignment: .center, spacing: 6) {
            MarkdownText(text: message.text)
                .font(Palette.messageFont)
                .lineSpacing(Palette.messageLineSpacing)
                .textSelection(.enabled)
                .bubble(owner: false)
                .fixedSize(horizontal: false, vertical: true)
                .contextMenu { menu }
            actions
            Spacer(minLength: 56)
        }
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var sentMessageContent: some View {
        VStack(alignment: .trailing, spacing: 4) {
            originLabel
            ReplyQuote(message: message)
            SentAttachments(message: message)
            if !message.text.isEmpty {
                Text(message.text)
                    .font(Palette.messageFont)
                    .lineSpacing(Palette.messageLineSpacing)
                    .textSelection(.enabled)
                    .bubble(owner: owner)
                    .contextMenu { menu }
                    .overlay(alignment: .bottomLeading) {
                        if !reactions.isEmpty {
                            ReactionBadge(reactions: reactions).offset(x: -8, y: 16)
                        }
                    }
                    .padding(.bottom, reactions.isEmpty ? 0 : 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            deliveryStatus
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
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(message.deliveryState == .failed ? .red : .secondary)
        }
    }

    @ViewBuilder private var originLabel: some View {
        if !owner {
            if message.origin?.kind == "bot" {
                Label(messageLabel(message), systemImage: "person.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                Text(messageLabel(message)).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    /// Reply and copy, shown beside a message while the pointer is over it.
    @ViewBuilder private var actions: some View {
        if replyable {
            HStack(spacing: 2) {
                actionButton("Reply", systemImage: "arrowshape.turn.up.left") { model.replyTo = message }
                actionButton("Copy", systemImage: "doc.on.doc") { copy() }
            }
            .opacity(hovered ? 1 : 0)
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    @ViewBuilder private var menu: some View {
        if replyable {
            Button("Reply") { model.replyTo = message }
        }
        Button("Copy") { copy() }
    }
}

/// Emoji a bot reacted with instead of replying, pinned to the corner of the message it answers.
struct ReactionBadge: View {
    let reactions: [String]

    var body: some View {
        Text(reactions.joined(separator: " "))
            .font(.system(size: 14))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
            .accessibilityLabel("Reacted \(reactions.joined(separator: " "))")
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
            .frame(maxWidth: Palette.column - 96, alignment: .leading)
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
