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
      let levels = board.levels(of: bot)
      if levels.count >= 2 { menu(levels) }
    }
    .task(id: "\(bot.id) \(bot.provider ?? "")") {
      if let client, let provider = bot.provider { await board.load(provider: provider, client: client) }
    }
  }

  private func menu(_ levels: [ThinkingLevel]) -> some View {
    let level = board.level(of: bot)
    return Menu {
      Picker("Reasoning", selection: Binding(get: { level }, set: { choose($0) })) {
        ForEach(levels) { Text($0.title).tag($0) }
      }
      .pickerStyle(.inline)
    } label: {
      label(level)
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
    .accessibilityValue(level.title)
    .help("Reasoning")
  }

  /// macOS draws its own indicator and keeps only the title of a menu's label.
  @ViewBuilder private func label(_ level: ThinkingLevel) -> some View {
    #if os(macOS)
      Text(level.title).font(.caption.weight(.medium)).lineLimit(1)
    #else
      HStack(spacing: 3) {
        Text(level.title)
        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .contentShape(.rect)
    #endif
  }
}
