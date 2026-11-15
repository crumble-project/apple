import apfelkern
import SwiftUI

/// The bot form's reasoning level, as the server's preview offers it for the model, and hidden with no choice
/// to make or no preview. The picker shows the level a turn runs at.
public struct ReasoningField: View {
  let preview: ReasoningPreview?
  @Binding var thinking: String

  public init(preview: ReasoningPreview?, thinking: Binding<String>) {
    self.preview = preview
    _thinking = thinking
  }

  public var body: some View {
    if let preview, preview.options.count > 1 {
      Picker("Reasoning", selection: Binding(get: { preview.effectiveLevel }, set: { thinking = $0.rawValue })) {
        ForEach(preview.options) { Text($0.label).tag($0.level) }
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
