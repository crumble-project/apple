import apfelkern
import SwiftUI

/// The sources on the Event relay page. Only the sheet ever holds a source's address.
struct EventSourceSection: View {
  @Environment(AppModel.self) private var model

  private var board: EventSourceBoard { model.connectedServices.eventSources }

  var body: some View {
    Section {
      if let error = board.readError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if board.isLoaded, board.sources.isEmpty {
        Text("No event sources yet.").foregroundStyle(.secondary)
      } else if !board.isLoaded, board.readError == nil {
        ProgressView()
      }
      ForEach(board.sources) { EventSourceRow(source: $0) }
    } header: {
      HStack {
        Text("Event sources")
        Spacer()
        Button("Add Source", systemImage: "plus") { board.open() }
          .textCase(nil)
      }
    } footer: {
      Text("Each source is one webhook address. Automations that use a source run when an event arrives there.")
        .foregroundStyle(.secondary)
    }
  }
}

private struct EventSourceRow: View {
  @Environment(AppModel.self) private var model
  let source: EventSource
  @State private var confirmingDelete = false

  private var error: String? { model.connectedServices.eventSources.errors[source.id] }

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(source.name).fontWeight(.semibold).lineLimit(1)
          Text("(\(source.usedByLabel))").foregroundStyle(.secondary)
        }
        // Touch has no tooltip, so the reason Delete is off stays on screen.
        if !source.canDelete {
          Text(source.deleteNote).font(.caption).foregroundStyle(.secondary)
        }
        if let error {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      Spacer()
      Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete \(source.name)")
        .disabled(!source.canDelete)
    }
    .confirmationDialog("Delete \(source.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { model.deleteEventSource(source) }
    } message: {
      Text("Its webhook address stops working. Events that already arrived are kept.")
    }
  }
}

/// Holds until the server answers, then shows the address once. Only Done closes it from there, so a
/// stray dismiss can't lose an address the server won't return again.
private struct EventSourceSheet: View {
  @Environment(AppModel.self) private var model
  @Binding var draft: EventSourceDraft

  private var board: EventSourceBoard { model.connectedServices.eventSources }

  var body: some View {
    NavigationStack {
      Group {
        if let created = draft.created { address(created) } else { editor }
      }
      .formStyle(.grouped)
      .navigationTitle(draft.created.map { "\($0.source.name) address" } ?? "Add event source")
    }
    .interactiveDismissDisabled(board.isSaving || draft.created != nil)
  }

  private var editor: some View {
    Form {
      ServiceSaveStatus(isSaving: board.isSaving, error: board.saveError)
      Section {
        TextField("Name", text: $draft.name, prompt: Text("GitHub issues"))
          .accessibilityLabel("Name")
          .onSubmit { model.saveEventSourceDraft() }
      } footer: {
        Text("Crumble creates the source on the relay and shows its webhook address once.")
          .foregroundStyle(.secondary)
      }
    }
    .disabled(board.isSaving)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(role: .cancel) { board.closeDraft() }.disabled(board.isSaving)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(role: .confirm) { model.saveEventSourceDraft() }.disabled(!board.canSave)
      }
    }
  }

  private func address(_ created: CreatedEventSource) -> some View {
    Form {
      Section {
        Text(created.address)
          .fontDesign(.monospaced)
          .font(.caption)
          .textSelection(.enabled)
          .privacySensitive()
          .accessibilityLabel("Webhook address")
        Button("Copy Address") { copyLocally(created.address) }
      } header: {
        Text("Webhook address")
      } footer: {
        Text("Shown once. Paste it into the provider's webhook settings.").foregroundStyle(.secondary)
      }
    }
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(role: .close) { board.closeDraft() }
      }
    }
  }
}

private struct EventSourceSheetModifier: ViewModifier {
  @Environment(AppModel.self) private var model

  private var board: EventSourceBoard { model.connectedServices.eventSources }

  private var draft: Binding<EventSourceDraft?> {
    Binding(
      get: { board.draft },
      set: { if $0 == nil { board.closeDraft() } else { board.draft = $0 } })
  }

  func body(content: Content) -> some View {
    content.sheet(item: draft) { EventSourceSheet(draft: sheetBinding(draft, for: $0)) }
  }
}

extension View {
  func eventSourceSheet() -> some View { modifier(EventSourceSheetModifier()) }
}
