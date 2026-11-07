import apfelkern
import BotAvatar
import SwiftUI

/// Every bot's credentials or logins, with a pill for each bot and search, as the web's pages.
struct BotSecretPanel: View {
  @Environment(AppModel.self) private var model
  let kind: BotSecretKind
  @State private var scope: String?
  @State private var search = ""

  private var board: BotSecretBoard { model.botSecretBoard }

  var body: some View {
    let page = board.page(kind, bots: model.agents, scope: scope, search: search)
    Form {
      Section {
        FilterPills(label: kind.pillsLabel, pills: pills(page), selection: $scope)
      }
      if !page.waiting.isEmpty {
        Section {
          ForEach(page.waiting) {
            BotSecretRequestRow(request: $0.request, kind: kind, agentID: $0.bot.id, botName: $0.bot.name)
          }
        } header: {
          Label("Waiting for you", systemImage: "bell")
        }
      }
      ForEach(page.groups) { group(for: $0) }
      if page.isLoading { ProgressView() }
      Section {
        if let note = page.note { Text(note).foregroundStyle(.secondary) }
      } footer: {
        Text(kind.note).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .searchable(text: $search, prompt: kind.searchPrompt)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("New \(kind.noun)", systemImage: "plus") { model.newBotSecret(kind, scope: page.scope) }
          .disabled(model.agents.isEmpty)
      }
    }
    .onChange(of: model.agents.map(\.id)) { model.loadBotSecrets(kind) }
  }

  private func pills(_ page: BotSecretPage) -> [FilterPill<String?>] {
    [FilterPill(value: nil, label: "All", count: page.total)]
      + model.agents.map {
        FilterPill(value: $0.id, label: $0.name, count: page.counts[$0.id], avatar: $0.avatar)
      }
  }

  private func group(for group: BotSecretPage.Group) -> some View {
    Section {
      if let error = group.error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if let note = group.note { Text(note).foregroundStyle(.secondary) }
      ForEach(group.items) { BotSecretRow(item: $0, agentID: group.bot.id) }
    } header: {
      Label {
        Text(group.bot.name)
      } icon: {
        BotAvatarView(agent: group.bot, size: 20)
      }
    }
  }
}
