import apfelkern
import SwiftUI

/// The composer's reasoning level, offered when the bot's model takes at least two.
public struct ReasoningControl: View {
  let board: ReasoningBoard
  let bot: Agent
  let client: APIClient?
  let choose: (ThinkingLevel) -> Void

  public init(board: ReasoningBoard, bot: Agent, client: APIClient?, choose: @escaping (ThinkingLevel) -> Void) {
    self.board = board
    self.bot = bot
    self.client = client
    self.choose = choose
  }

  public var body: some View {
    // A ZStack, because a Group would run the task on each branch and on none while hidden.
    ZStack {
      if let preview = board.preview(of: bot, client: client), preview.options.count >= 2 { menu(preview) }
    }
    .task(id: board.previewKey(of: bot, client: client)) {
      if let client { await board.loadPreview(bot: bot, client: client) }
    }
  }

  private func menu(_ preview: Components.Schemas.ReasoningPreview) -> some View {
    let level = board.pendingLevels[bot.id] ?? preview.effectiveLevel.rawValue
    let title = preview.options.first { $0.value.rawValue == level }?.label ?? level
    return Menu {
      Picker("Reasoning", selection: Binding(get: { level }, set: { value in
        if let choice = ThinkingLevel(rawValue: value) { choose(choice) }
      })) {
        ForEach(preview.options, id: \.value) { Text($0.label).tag($0.value.rawValue) }
      }
      .pickerStyle(.inline)
    } label: {
      label(title)
    }
    .menuStyle(.button)
    #if os(macOS)
      .buttonStyle(.borderless)
      .menuIndicator(.visible)
      .tint(.secondary)
    #else
      .buttonStyle(.plain)
    #endif
    .fixedSize()
    .disabled(board.saving.contains(bot.id))
    .accessibilityLabel("Reasoning")
    .accessibilityValue(title)
    .help("Reasoning")
  }

  /// macOS draws its own indicator and keeps only the title of a menu's label.
  @ViewBuilder private func label(_ title: String) -> some View {
    #if os(macOS)
      Text(title).font(.caption.weight(.medium)).lineLimit(1)
    #else
      HStack(spacing: 3) {
        Text(title)
        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .contentShape(.rect)
    #endif
  }
}
