import apfelkern
import SwiftUI

/// The account's passkeys in a settings form. Adding one needs WebAuthn at the server's own address,
/// so that stays on the web; the rest needs only a session.
public struct PasskeysSection: View {
  private let board: PasskeyBoard
  private let client: APIClient?
  @State private var renaming: Passkey?
  @State private var name = ""
  @State private var removing: Passkey?

  public init(board: PasskeyBoard, client: APIClient?) {
    self.board = board
    self.client = client
  }

  public var body: some View {
    Section {
      if board.passkeys.isEmpty, board.isLoaded {
        Text("No passkeys yet.").foregroundStyle(.secondary)
      } else if board.passkeys.isEmpty, board.error == nil {
        ProgressView()
      }
      ForEach(board.passkeys) { row($0) }
      if let error = board.error {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    } header: {
      Text("Passkeys")
    } footer: {
      if let client { Text(Passkey.footer(serverURL: client.baseURL)).foregroundStyle(.secondary) }
    }
    .alert("Rename Passkey", isPresented: isRenaming, presenting: renaming) { passkey in
      TextField("Passkey name", text: $name)
      Button("Save") {
        if let client { board.rename(passkey.id, to: name, client: client) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Remove this passkey?", isPresented: isRemoving, presenting: removing
    ) { passkey in
      Button("Remove", role: .destructive) {
        if let client { board.remove(passkey.id, client: client) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { passkey in
      Text("You can no longer sign in with \(passkey.title).")
    }
  }

  private var isRenaming: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }

  private var isRemoving: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }

  private func row(_ passkey: Passkey) -> some View {
    HStack {
      Image(systemName: "person.badge.key").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(passkey.title).lineLimit(1)
        Text(passkey.detail).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        Button("Rename…") {
          name = passkey.name ?? ""
          renaming = passkey
        }
        Button("Remove…", role: .destructive) { removing = passkey }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .buttonStyle(.borderless)
      .fixedSize()
      .accessibilityLabel("Passkey actions")
      .disabled(board.isBusy(passkey.id))
    }
  }
}
