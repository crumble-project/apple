import apfelkern
import SwiftUI

/// The bot form's reasoning level, limited to what the model supports and hidden with no choice to make.
public struct ReasoningField: View {
  let levels: [ThinkingLevel]
  @Binding var thinking: String

  public init(levels: [ThinkingLevel], thinking: Binding<String>) {
    self.levels = levels
    _thinking = thinking
  }

  private var level: ThinkingLevel {
    (ThinkingLevel(rawValue: thinking) ?? .off).clamped(to: levels)
  }

  public var body: some View {
    if levels.count > 1 {
      Picker("Reasoning", selection: Binding(get: { level }, set: { thinking = $0.rawValue })) {
        ForEach(levels) { Text($0.title).tag($0) }
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
