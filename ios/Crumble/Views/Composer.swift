import apfelkern
import BotAvatar
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
  static let height: CGFloat = 44
  @Environment(AppModel.self) private var model
  let target: ComposerTarget
  @State private var selection: NSRange?
  @State private var selectedMention = 0
  @State private var dismissedMention = false
  @State private var importing = false
  @State private var photoItems: [PhotosPickerItem] = []

  var body: some View {
    @Bindable var model = model
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
      controls
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 14)
    .fileImporter(
      isPresented: $importing, allowedContentTypes: [.image, .text, .sourceCode, .json, .xml],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): model.addAttachments(urls)
      case .failure(let error): model.errorText = error.localizedDescription
      }
    }
    .onChange(of: photoItems) { _, items in
      importPhotos(items)
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard target.enabled else { return false }
      model.addAttachments(urls)
      return true
    }
  }
}

extension Composer {
  private var controls: some View {
    HStack(alignment: .bottom, spacing: 8) {
      attachmentMenu
      messageField
      sendControl
    }
  }

  private var attachmentMenu: some View {
    // Drawn as a glass circle of the field's height; the glass button style keeps its own smaller size.
    Menu {
      PhotosPicker(
        selection: $photoItems, maxSelectionCount: AttachmentLimits.count,
        matching: .images
      ) {
        Label("Photos", systemImage: "photo")
      }
      Button {
        importing = true
      } label: {
        Label("Files", systemImage: "doc")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 16, weight: .medium))
        .frame(width: Composer.height, height: Composer.height)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .circle)
    .disabled(!target.enabled)
    .accessibilityLabel("Attach Files")
    .help("Attach images or text files")
  }

  private var canSend: Bool {
    target.enabled
      && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty)
  }

  @ViewBuilder private var sendControl: some View {
    if target.running {
      Button {
        target.stop()
      } label: {
        Image(systemName: "stop.fill")
          .font(.system(size: 16, weight: .medium))
          .frame(width: Composer.height, height: Composer.height)
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .accessibilityLabel("Stop")
      .help(target.stopHelp)
    }
    if !target.running || canSend {
      Button {
        target.send()
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 16, weight: .bold))
          .frame(width: Composer.height, height: Composer.height)
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .disabled(!canSend)
      .accessibilityLabel("Send")
    }
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    photoItems = []
    importAttachments(items) { item in
      guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else { return nil }
      let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crumble-photo-\(UUID().uuidString)")
        .appendingPathExtension(ext)
      try data.write(to: url, options: [.atomic])
      defer { try? FileManager.default.removeItem(at: url) }
      return try loadAttachment(from: url)
    }
  }

  /// Files arrive after a delay, so each lands only in the conversation it was meant for.
  private func importAttachments<Item>(
    _ items: [Item], load: @escaping @MainActor (Item) async throws -> PendingAttachment?
  ) {
    guard !items.isEmpty else { return }
    let conversation = model.conversationKey
    let serverURL = model.client?.baseURL
    let serverToken = model.client?.token
    Task {
      for item in items {
        do {
          let attachment = try await load(item)
          guard model.conversationKey == conversation,
            model.client?.baseURL == serverURL,
            model.client?.token == serverToken
          else { return }
          guard let attachment else { continue }
          guard model.attachments.count < AttachmentLimits.count else {
            model.errorText = "A message can carry up to \(AttachmentLimits.count) files."
            return
          }
          model.attachments.append(attachment)
        } catch {
          model.errorText = error.localizedDescription
        }
      }
    }
  }

  private var draftField: some View {
    @Bindable var model = model
    return ComposerTextView(
      text: $model.draft, selection: $selection, label: target.placeholder, enabled: target.enabled,
      onKey: handleKey,
      onPaste: { importAttachments($0, load: pastedAttachment) }
    )
    .overlay(alignment: .topLeading) {
      if model.draft.isEmpty {
        Text(target.placeholder)
          .foregroundStyle(.placeholder)
          .lineLimit(1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, 7)
    .onChange(of: model.draft) { _, _ in
      selectedMention = 0
      dismissedMention = false
    }
  }

  private var messageRow: some View {
    HStack(alignment: .bottom, spacing: 8) {
      draftField
      if let bot = target.bot {
        ReasoningControl(board: model.reasoningBoard, bot: bot, client: model.client) {
          model.reasoningBoard.choose($0, for: bot.id, host: model)
        }
        .padding(.bottom, 10)
      }
    }
  }

  private func handleKey(_ key: ComposerKey) -> Bool {
    switch key {
    case .send:
      if !acceptMention() { target.send() }
      return true
    case .tab:
      return acceptMention()
    case .escape:
      guard completion != nil, !dismissedMention else { return false }
      dismissedMention = true
      return true
    case .arrowUp:
      return cycleMention(by: -1)
    case .arrowDown:
      return cycleMention(by: 1)
    }
  }

  nonisolated private static func attachment(
    at url: URL?, error: (any Error)?
  ) -> Result<PendingAttachment, any Error> {
    Result {
      guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
      return try loadAttachment(from: url)
    }
  }

  /// Reads an item as a file; the file exists only during the callback.
  private func pastedAttachment(_ provider: NSItemProvider) async throws -> PendingAttachment? {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      return try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, error in
          continuation.resume(with: Self.attachment(at: url, error: error))
        }
      }
    }
    guard let type = PasteContent.fileType(in: provider.registeredTypeIdentifiers) else { return nil }
    var attachment = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
        continuation.resume(with: Self.attachment(at: url, error: error))
      }
    }
    let name = provider.suggestedName ?? (type.conforms(to: .image) ? "Pasted image" : "Pasted file")
    attachment.name = (name as NSString).deletingPathExtension + "." + (attachment.name as NSString).pathExtension
    return attachment
  }

  private var messageField: some View {
    VStack(alignment: .leading, spacing: 6) {
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
      messageRow
      if let completion, !dismissedMention {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(Array(completion.bots.enumerated()), id: \.element.id) { index, bot in
              Button("@\(bot.name)") { _ = acceptMention(index: index) }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .tint(index == selectedMention ? .accentColor : .secondary)
                .controlSize(.small)
            }
          }
        }
      }
    }
    .padding(.leading, 14)
    .padding(.trailing, 14)
    .padding(.vertical, 4)
    .frame(minHeight: Composer.height)
    .glassEffect(.regular, in: .rect(cornerRadius: Composer.height / 2))
  }

  private var completion: MentionCompletion? {
    let text = model.draft
    let end = NSRange(location: (text as NSString).length, length: 0)
    let caret = selection.flatMap { $0.upperBound <= end.location ? $0 : nil } ?? end
    return MentionCompletion.find(in: text, selection: caret, bots: target.mentionable)
  }

  private func acceptMention(index: Int? = nil) -> Bool {
    guard !dismissedMention, let completion,
      let range = Range(completion.range, in: model.draft)
    else { return false }
    let bot = completion.bots[min(index ?? selectedMention, completion.bots.count - 1)]
    model.draft.replaceSubrange(range, with: "@" + bot.name + " ")
    selection = nil
    return true
  }

  private func cycleMention(by direction: Int) -> Bool {
    guard !dismissedMention, let completion else { return false }
    selectedMention = (selectedMention + direction + completion.bots.count) % completion.bots.count
    return true
  }
}
