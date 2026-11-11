import apfelkern
import AppKit
import BotAvatar
import SwiftUI

extension ComposerTarget {
    /// A bot chat: mentions complete to every other enabled bot, and the composer sets its reasoning.
    @MainActor static func chat(_ agent: Agent, model: AppModel) -> ComposerTarget {
        ComposerTarget(
            placeholder: agent.enabled
                ? "Message \(agent.name)" : "\(agent.name) is paused. Enable it in its profile.",
            enabled: agent.enabled,
            mentionable: agent.mentionableBots(in: model.agents),
            bot: agent,
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
    @Environment(\.controlActiveState) private var windowState
    let target: ComposerTarget
    @FocusState private var focused: Bool
    @State private var pasteMonitor: PasteMonitor?
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
        .onAppear { if !model.sidebarFocused { focused = true } }
        .onChange(of: model.composerFocusRequest) { focused = true }
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
        .onChange(of: focused && target.enabled && windowState == .key, initial: true) { _, accepts in
            pasteMonitor = accepts ? PasteMonitor(model: model) : nil
        }
        .onDisappear { pasteMonitor = nil }
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
            .card()
        }
    }

    /// One raised field holds everything: attach on the leading edge, then the message, reasoning, and send.
    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            pendingAttachments
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                messageRow
                    .frame(minHeight: Composer.height)
                if target.running {
                    stopButton
                }
                if !target.running || canSend {
                    sendButton
                }
            }
        }
        .padding(6)
        .card(cornerRadius: (Composer.height + 12) / 2)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(canSend ? AnyShapeStyle(Palette.onInk) : AnyShapeStyle(.tertiary))
                .frame(width: Composer.height, height: Composer.height)
                .background(canSend ? Palette.ink : Palette.bubble, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: canSend)
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Composer.height, height: Composer.height)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!target.enabled)
        .accessibilityLabel("Attach Files")
        .help("Attach images or text files")
    }

    @ViewBuilder private var pendingAttachments: some View {
        if !model.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.attachments) { file in
                        PendingAttachmentChip(file: file) { model.removeAttachment(file.id) }
                    }
                }
                .padding([.top, .horizontal], 6)
            }
        }
    }

    private var messageRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            messageInput
            if let bot = target.bot {
                ReasoningControl(board: model.reasoningBoard, bot: bot, client: model.client) {
                    model.reasoningBoard.choose($0, for: bot.id, host: model)
                }
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
        .padding(.vertical, 7)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.onInk)
                .frame(width: Composer.height, height: Composer.height)
                .background(Palette.ink, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
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

/// The field editor takes Paste before SwiftUI's paste commands see it, so ⌘V is caught on its way there
/// while the composer has focus. It lives as long as this object.
@MainActor
final class PasteMonitor {
    private var monitor: Any?

    init(model: AppModel, pasteboard: NSPasteboard = .general) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isPaste(event) else { return event }
            return MainActor.assumeIsolated { model.pasteAttachments(from: pasteboard) } ? nil : event
        }
    }

    nonisolated static func isPaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers == "v"
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
