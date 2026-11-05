import apfelkern
import OpenBotAvatar
import SwiftUI

/// Colors and the three ways to choose a shape: the gallery, importing a definition, and copying a
/// prompt to design one elsewhere. Changes stay in the draft until the bot is saved.
public struct BotAvatarEditor: View {
  private enum Tab: String, CaseIterable, Identifiable {
    case gallery = "Gallery", importing = "Import", generate = "Generate"
    var id: Self { self }
  }

  @Binding private var value: BotAvatarDefinition
  @State private var tab = Tab.gallery
  @State private var colorDraft: String
  @State private var eyeDraft: String
  @State private var json = ""
  @State private var description = ""
  @State private var error = ""
  @State private var status = ""

  public init(value: Binding<BotAvatarDefinition>) {
    _value = value
    _colorDraft = State(initialValue: value.wrappedValue.color)
    _eyeDraft = State(initialValue: value.wrappedValue.eyeColor)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        colorField("Body color", text: $colorDraft)
        colorField("Eye color", text: $eyeDraft)
      }
      Picker("Avatar source", selection: $tab) {
        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      switch tab {
      case .gallery: gallery
      case .importing: importPane
      case .generate: generatePane
      }
      if !error.isEmpty {
        Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      if !status.isEmpty {
        Text(status).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func colorField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline)
      TextField(title, text: limited(text, to: 7))
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(width: 112)
        .plainTextInput()
        .onChange(of: text.wrappedValue) { applyColors() }
    }
  }

  private var gallery: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
        ForEach(AvatarCatalog.all) { definition in
          let selected = definition.id == value.definition.id
          Button {
            value.definition = definition
            error = ""
            status = ""
          } label: {
            VStack(spacing: 4) {
              BotAvatarView(
                avatar: BotAvatarDefinition(definition: definition, color: value.color, eyeColor: value.eyeColor),
                size: 48)
              Text(definition.name).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Pick \(definition.name)")
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }
    .frame(height: 288)
  }

  private var importPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Definition JSON").font(.subheadline)
      editor($json, limit: 16000, accessibilityLabel: "Definition JSON")
      Button("Validate and import") { importJSON() }.buttonStyle(.bordered)
    }
  }

  private var generatePane: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Describe your avatar").font(.subheadline)
      editor($description, limit: 4000, accessibilityLabel: "Describe your avatar")
      Text(
        """
        Copy the Open Bot Avatar prompt with your description. Give it to any bot or model, then paste \
        its definition JSON into Import. A bot can also suggest its own avatar in chat. Nothing is \
        generated or sent from this page.
        """
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button("Copy generation prompt") { copyPrompt() }
        .buttonStyle(.bordered)
        .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private func editor(_ text: Binding<String>, limit: Int, accessibilityLabel: String) -> some View {
    TextEditor(text: limited(text, to: limit))
      .font(.body.monospaced())
      .frame(height: 120)
      .scrollContentBackground(.hidden)
      .padding(4)
      .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
      .plainTextInput()
      .accessibilityLabel(accessibilityLabel)
  }

  private func limited(_ text: Binding<String>, to limit: Int) -> Binding<String> {
    Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
  }

  private func applyColors() {
    if let colored = value.recolored(color: colorDraft, eyeColor: eyeDraft) {
      if colored != value { value = colored }
      error = ""
    } else {
      error = "Colors must be #rgb or #rrggbb."
    }
  }

  private func importJSON() {
    switch value.importing(json: json) {
    case .success(let imported):
      value = imported
      error = ""
      status = "Avatar imported. Save the bot to keep it."
    case .failure(let failure):
      error = failure.errors.joined(separator: "\n")
      status = ""
    }
  }

  private func copyPrompt() {
    copyToPasteboard(BotAvatarDefinition.generationPrompt(description))
    status = "Prompt copied. Give it to any bot or model, then paste its JSON into Import."
    error = ""
  }
}

private func copyToPasteboard(_ text: String) {
  #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  #else
    UIPasteboard.general.string = text
  #endif
}

extension View {
  fileprivate func plainTextInput() -> some View {
    #if os(macOS)
      autocorrectionDisabled()
    #else
      textInputAutocapitalization(.never).autocorrectionDisabled()
    #endif
  }
}
