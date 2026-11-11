import apfelkern
import SwiftUI

/// The bot form's reasoning level, limited to what the model supports and hidden with no choice to make.
public struct ReasoningField: View {
  let draftID: UUID
  let provider: String
  let model: String
  let client: APIClient?
  @Binding var thinking: String
  @State private var preview: Components.Schemas.ReasoningPreview?
  @State private var context = ""
  @State private var pending = false

  public init(draftID: UUID, provider: String, model: String, client: APIClient?, thinking: Binding<String>) {
    self.draftID = draftID
    self.provider = provider
    self.model = model
    self.client = client
    _thinking = thinking
  }

  private var contextKey: String {
    [draftID.uuidString, client?.baseURL ?? "", client?.token ?? "", provider, model].joined(separator: "\u{0}")
  }

  public var body: some View {
    Group {
      if context == contextKey, let preview, preview.options.count > 1 {
        let selected = pending ? thinking : preview.effectiveLevel.rawValue
        Picker("Reasoning", selection: Binding(get: { selected }, set: { thinking = $0 })) {
          ForEach(preview.options, id: \.value) { Text($0.label).tag($0.value.rawValue) }
        }
      }
    }
    .task(id: contextKey + "\u{0}" + thinking) {
      let key = contextKey
      let level = thinking
      if context != key { preview = nil; context = key }
      pending = true
      guard let client else { pending = false; return }
      do {
        try await Task.sleep(for: .milliseconds(250))
        let loaded = try await client.previewReasoning(provider: provider, model: model, level: level)
        guard !Task.isCancelled, contextKey == key, thinking == level else { return }
        preview = loaded
        pending = false
      } catch {
        if !Task.isCancelled, contextKey == key { pending = false }
      }
    }
  }
}

/// The desktop job's model, suggesting what its own provider offers. The field stays free text.
public struct DesktopModelField: View {
  let provider: String
  let client: APIClient?
  @Binding var model: String
  @State private var models: [ModelSummary] = []

  public init(provider: String, client: APIClient?, model: Binding<String>) {
    self.provider = provider
    self.client = client
    _model = model
  }

  public var body: some View {
    field
      .task(id: provider) {
        models = []
        guard let client else { return }
        let loaded = try? await client.models(provider: provider)
        if !Task.isCancelled { models = loaded ?? [] }
      }
  }

  @ViewBuilder private var field: some View {
    #if os(macOS)
      TextField("Desktop job model", text: $model, prompt: Text("Model ID"))
        .textInputSuggestions {
          ForEach(models, id: \.id) { Text($0.id).textInputCompletion($0.id) }
        }
    #else
      HStack {
        TextField("Desktop job model", text: $model, prompt: Text("Model ID"))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        if !models.isEmpty {
          Menu {
            ForEach(models, id: \.id) { summary in
              Button(summary.id) { model = summary.id }
            }
          } label: {
            Image(systemName: "list.bullet")
          }
          .accessibilityLabel("Choose a desktop job model")
        }
      }
    #endif
  }
}

/// Marks an activity entry whose tool call failed.
public struct ActivityErrorBadge: View {
  public init() {}

  public var body: some View {
    Text("Error")
      .font(.caption.weight(.medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(.red, in: .capsule)
  }
}
