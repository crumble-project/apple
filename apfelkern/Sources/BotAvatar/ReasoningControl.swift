import apfelkern
import SwiftUI

/// The composer's reasoning level, offered when the server says the bot's model takes at least two.
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
      if let preview = board.preview(of: bot), preview.options.count >= 2 { menu(preview) }
    }
    .task(id: previewInputs) {
      if let client { await board.load(bot: bot, client: client) }
    }
  }

  /// What the server's preview depends on, including the connection, whose previews a reset drops.
  private var previewInputs: [String] {
    [client?.baseURL ?? "", client?.token ?? "", bot.provider ?? "", bot.model ?? "",
     bot.inference?.thinkingLevel ?? ""]
  }

  private func menu(_ preview: ReasoningPreview) -> some View {
    Menu {
      Picker("Reasoning", selection: Binding(get: { preview.effectiveLevel }, set: { choose($0) })) {
        ForEach(preview.options) { Text($0.label).tag($0.level) }
      }
      .pickerStyle(.inline)
    } label: {
      label(preview.label)
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
    .accessibilityValue(preview.label)
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
