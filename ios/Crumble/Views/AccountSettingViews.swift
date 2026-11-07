import apfelkern
import SwiftUI

struct WebSearchPanel: View {
  @Environment(AppModel.self) private var model

  private var board: AccountSettingBoard<WebSearchSettings> { model.connectedServices.webSearch }

  var body: some View {
    Form {
      Section {
        if let error = board.readError {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        if let setting = board.setting {
          LabeledContent("Default") {
            Picker("Default web search provider", selection: Binding(
              get: { setting.defaultProvider },
              set: { model.chooseAccountSetting($0, on: board) })
            ) {
              ForEach(WebSearchProvider.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }
          if let note = board.saveError ?? setting.warning {
            Text(note).font(.caption).foregroundStyle(.secondary)
          }
          PluginSettingRows(selection: .contributes(.webSearchProviders))
        } else if board.readError == nil {
          ProgressView()
        }
      } header: {
        Text("Search provider")
      } footer: {
        Text("Bots use this unless their own settings choose another provider.")
      }
    }
    .formStyle(.grouped)
  }
}

struct ModelSettingPanel<Setting: ModelSetting>: View {
  @Environment(AppModel.self) private var model
  let board: AccountSettingBoard<Setting>

  var body: some View {
    Form {
      Section {
        if let error = board.readError {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        if let setting = board.setting {
          Picker(Setting.title, selection: Binding(
            get: { setting.choice },
            set: { model.chooseAccountSetting($0, on: board) })
          ) {
            ForEach(setting.options) { Text($0.label).tag($0.ref) }
          }
          Text(board.saveError ?? setting.status).font(.caption).foregroundStyle(.secondary)
        } else if board.readError == nil {
          ProgressView()
        }
      } header: {
        Text(Setting.sectionTitle)
      } footer: {
        Text(Setting.sectionNote)
      }
    }
    .formStyle(.grouped)
  }
}
