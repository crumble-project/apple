import apfelkern
import BotAvatar
import SwiftUI

/// Try out an avatar, and save it to a bot once one is chosen.
struct AvatarsPanel: View {
  @Environment(AppModel.self) private var model

  private var board: AvatarBoard { model.avatarBoard }

  private var bot: Binding<String> {
    Binding(get: { board.botID }, set: { id in board.select(model.agents.first { $0.id == id }) })
  }

  var body: some View {
    @Bindable var board = board
    Form {
      Section {
        Text("Choose a gallery shape, import a definition, or copy a prompt to design your own.")
          .foregroundStyle(.secondary)
        HStack {
          preview(.idle, "Idle")
          preview(.working, "Working")
          preview(.sleeping, "Sleeping")
        }
      }
      Section {
        Picker("Bot to edit", selection: bot) {
          Text("Preview only").tag("")
          ForEach(model.agents) { Text($0.name).tag($0.id) }
        }
        BotAvatarEditor(value: $board.value).id(board.botID)
      }
      Section {
        Button("Save avatar to bot") { model.saveAvatar() }.disabled(!board.canSave)
        if !board.saveError.isEmpty {
          Text(board.saveError).foregroundStyle(.red).textSelection(.enabled)
        } else if board.saved {
          Text("Avatar saved.").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: model.agents.map(\.id), initial: true) { _, ids in board.keepSelection(in: ids) }
  }

  private func preview(_ state: BotState, _ label: String) -> some View {
    VStack(spacing: 8) {
      BotAvatarView(avatar: board.value, size: 96, state: state, live: true)
      Text(label).font(.subheadline)
    }
    .frame(maxWidth: .infinity)
  }
}
