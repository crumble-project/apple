import apfelkern
import AppKit
import SwiftUI

/// What the composer writes to: a bot chat or a group chat.
struct ComposerTarget {
    var placeholder: String
    var enabled: Bool
    /// Bots that `@` completes.
    var mentionable: [Agent]
    var running: Bool
    var stopHelp: String
    var send: @MainActor () -> Void
    var stop: @MainActor () -> Void
}

extension ComposerTarget {
    /// A bot chat: mentions complete to the bots the bot may message.
    @MainActor static func chat(_ agent: Agent, model: AppModel) -> ComposerTarget {
        ComposerTarget(
            placeholder: agent.enabled
                ? "Message \(agent.name)" : "\(agent.name) is paused. Enable it in its profile.",
            enabled: agent.enabled,
            mentionable: model.agents.filter {
                $0.enabled && $0.id != agent.id && (agent.delegates ?? []).contains($0.id)
                    && (agent.tools ?? []).contains("delegate")
            },
            running: model.snapshot?.isRunning == true,
            stopHelp: "Stop the current run",
            send: { model.sendMessage() },
            stop: { model.abortChat() })
    }
}

struct Composer: View {
    /// The height of the message field and the attach button beside it.
    static let height: CGFloat = 32
    @Environment(AppModel.self) private var model
    let target: ComposerTarget
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    @State private var selectedMention = 0
    @State private var dismissedMention = false
    @State private var importing = false

    var body: some View {
        VStack(spacing: 6) {
            replyPreview
            inputRow
        }
        .frame(maxWidth: Palette.column)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: [.image, .text, .sourceCode, .json, .xml],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.addAttachments(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard target.enabled else { return false }
            model.addAttachments(urls)
            return true
        }
    }

    @ViewBuilder private var replyPreview: some View {
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
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton
            messageField
            if target.running {
                stopButton
            }
            if !target.running || canSend {
                sendButton
            }
        }
    }

    private var canSend: Bool {
        target.enabled
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty)
    }

    private var sendButton: some View {
        Button {
            target.send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .frame(width: Composer.height, height: Composer.height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .composerGlass(canSend ? .regular.tint(.accentColor).interactive() : .regular, in: .circle)
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .help("Send (Return)")
    }

    private var attachButton: some View {
        // Drawn as a glass circle of the field's height; the glass button style keeps its own smaller size.
        Button {
            importing = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .frame(width: Composer.height, height: Composer.height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .composerGlass(.regular.interactive(), in: .circle)
        .disabled(!target.enabled)
        .accessibilityLabel("Attach Files")
        .help("Attach images or text files")
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            pendingAttachments
            messageInput
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .frame(minHeight: Composer.height)
        .composerGlass(.regular, in: .rect(cornerRadius: Composer.height / 2))
    }

    @ViewBuilder private var pendingAttachments: some View {
        if !model.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.attachments) { file in
                        PendingAttachmentChip(file: file) { model.removeAttachment(file.id) }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var messageInput: some View {
        @Bindable var model = model
        return TextField(
            target.placeholder,
            text: $model.draft, selection: $selection, axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(Palette.messageFont)
        .lineLimit(1...8)
        .focused($focused)
        .disabled(!target.enabled)
        .overlay(alignment: .topLeading) {
            if let completion, !dismissedMention {
                let bot = completion.bots[min(selectedMention, completion.bots.count - 1)]
                let suffix = String(bot.name.dropFirst(completion.query.count))
                Text(
                    "\(Text(model.draft).foregroundStyle(.clear))\(Text(suffix + " ⇥").foregroundStyle(.tertiary))"
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .onChange(of: model.draft) { _, _ in
            selectedMention = 0
            dismissedMention = false
        }
        .onKeyPress(.tab) { acceptMention() ? .handled : .ignored }
        .onKeyPress(.escape) {
            guard completion != nil, !dismissedMention else { return .ignored }
            dismissedMention = true
            return .handled
        }
        .onKeyPress(.downArrow) { cycleMention(by: 1) }
        .onKeyPress(.upArrow) { cycleMention(by: -1) }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                var range: Range<String.Index>?
                if case .selection(let selected)? = selection?.indices { range = selected }
                let (text, caret) = insertingNewline(into: model.draft, replacing: range)
                model.draft = text
                selection = TextSelection(insertionPoint: caret)
            } else if !acceptMention() {
                target.send()
            }
            return .handled
        }
    }

    private var stopButton: some View {
        Button {
            target.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 16, weight: .medium))
                .frame(width: Composer.height, height: Composer.height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .composerGlass(.regular.interactive(), in: .circle)
        .accessibilityLabel("Stop")
        .help(target.stopHelp)
    }

    private var completion: MentionCompletion? {
        let text = model.draft
        var caret = NSRange(location: (text as NSString).length, length: 0)
        if case .selection(let range)? = selection?.indices,
            range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            caret = NSRange(range, in: text)
        }
        return MentionCompletion.find(in: text, selection: caret, bots: target.mentionable)
    }

    private func acceptMention() -> Bool {
        guard !dismissedMention, let completion,
            let range = Range(completion.range, in: model.draft)
        else { return false }
        let bot = completion.bots[min(selectedMention, completion.bots.count - 1)]
        model.draft.replaceSubrange(range, with: "@" + bot.name + " ")
        selection = TextSelection(insertionPoint: model.draft.endIndex)
        return true
    }

    private func cycleMention(by direction: Int) -> KeyPress.Result {
        guard !dismissedMention, let completion else { return .ignored }
        selectedMention = (selectedMention + direction + completion.bots.count) % completion.bots.count
        return .handled
    }
}

extension View {
    /// Glass alone all but vanishes over the plain chat background, so the composer's pieces get a
    /// hairline edge and a soft shadow.
    fileprivate func composerGlass(_ glass: Glass, in shape: some InsettableShape) -> some View {
        glassEffect(glass, in: shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
