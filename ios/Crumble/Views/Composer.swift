import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
  /// The height of the message field and the attach button beside it.
  static let height: CGFloat = 44
  @Environment(AppModel.self) private var model
  let agent: Agent
  @FocusState private var focused: Bool
  @State private var selection: TextSelection?
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
      guard agent.enabled else { return false }
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
    .disabled(!agent.enabled)
    .accessibilityLabel("Attach Files")
    .help("Attach images or text files")
  }

  @ViewBuilder private var sendControl: some View {
    let running = model.snapshot?.isRunning == true
    if running {
      Button {
        model.abortChat()
      } label: {
        Image(systemName: "stop.fill")
          .font(.system(size: 16, weight: .medium))
          .frame(width: Composer.height, height: Composer.height)
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .accessibilityLabel("Stop")
      .help("Stop the current run")
    } else {
      Button {
        model.sendMessage()
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 16, weight: .bold))
          .frame(width: Composer.height, height: Composer.height)
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .disabled(
        !agent.enabled
          || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.attachments.isEmpty)
      )
      .accessibilityLabel("Send")
    }
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    guard !items.isEmpty else { return }
    let agentID = agent.id
    let serverURL = model.client?.baseURL
    let serverToken = model.client?.token
    photoItems = []
    Task {
      for item in items {
        guard let data = try? await item.loadTransferable(type: Data.self),
          !data.isEmpty
        else { continue }
        guard model.selectedAgent?.id == agentID,
          model.client?.baseURL == serverURL,
          model.client?.token == serverToken
        else { return }
        guard model.attachments.count < AttachmentLimits.count else {
          model.errorText = "A message can carry up to \(AttachmentLimits.count) files."
          return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("crumble-photo-\(UUID().uuidString)")
          .appendingPathExtension(ext)
        do {
          try data.write(to: url, options: [.atomic])
          defer { try? FileManager.default.removeItem(at: url) }
          model.attachments.append(try loadAttachment(from: url))
        } catch {
          model.errorText = error.localizedDescription
        }
      }
    }
  }

  private var draftField: some View {
    @Bindable var model = model
    return TextField(
      agent.enabled
        ? "Message \(agent.name)" : "\(agent.name) is paused. Enable it in its profile.",
      text: $model.draft, selection: $selection, axis: .vertical
    )
    .textFieldStyle(.plain)
    .lineLimit(1...8)
    .focused($focused)
    .disabled(!agent.enabled)
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
        model.sendMessage()
      }
      return .handled
    }
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
      draftField
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
    var caret = NSRange(location: (text as NSString).length, length: 0)
    if case .selection(let range)? = selection?.indices,
      range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
      caret = NSRange(range, in: text)
    }
    let bots = model.agents.filter {
      $0.enabled && $0.id != agent.id && (agent.delegates ?? []).contains($0.id)
        && (agent.tools ?? []).contains("delegate")
    }
    return MentionCompletion.find(in: text, selection: caret, bots: bots)
  }

  private func acceptMention(index: Int? = nil) -> Bool {
    guard !dismissedMention, let completion,
      let range = Range(completion.range, in: model.draft)
    else { return false }
    let bot = completion.bots[min(index ?? selectedMention, completion.bots.count - 1)]
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
