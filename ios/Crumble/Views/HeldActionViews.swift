import apfelkern
import SwiftUI

/// A desktop job action an intent check held: the owner approves or declines it here.
struct HeldActionCard: View {
  @Environment(AppModel.self) private var model
  let held: HeldActionEvent
  let title: String

  var body: some View {
    switch model.heldActionBoard.state(of: held.id) {
    case .waiting(let action):
      HeldActionDecisionView(action: action)
    case .outcome(let outcome):
      HStack(spacing: 10) {
        Image(systemName: "hand.raised").foregroundStyle(.secondary)
        Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
        Spacer(minLength: 0)
        Text(outcome).font(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: 380, alignment: .leading)
      .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
      .accessibilityElement(children: .combine)
    }
  }
}

private struct HeldActionDecisionView: View {
  @Environment(AppModel.self) private var model
  let action: HeldAction
  @State private var showsMessages = false
  @FocusState private var reasonFocused: Bool

  private var decision: HeldActionDecision { model.heldActionBoard.decision(for: action.id) }
  private var reason: Binding<String> {
    Binding(
      get: { decision.reason },
      set: { model.heldActionBoard.decisions[action.id, default: HeldActionDecision()].reason = $0 })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      checkedAgainst
      if !decision.error.isEmpty {
        Text(decision.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      if decision.declining {
        TextField("Reason", text: reason, prompt: Text("Reason (optional)"))
          .textFieldStyle(.roundedBorder)
          .disabled(decision.sending)
          .accessibilityLabel("Reason")
          .focused($reasonFocused)
          .onAppear { reasonFocused = true }
      }
      buttons
    }
    .padding(12)
    .frame(maxWidth: 380, alignment: .leading)
    .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "hand.raised").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(action.job) is waiting for your approval")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(action.action).font(.subheadline.weight(.medium)).textSelection(.enabled)
        if let page = action.page {
          Text(page)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
  }

  private var checkedAgainst: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(action.reason).textSelection(.enabled)
      Button {
        showsMessages.toggle()
      } label: {
        Text(showsMessages ? "Hide your messages" : "Checked against your messages").underline()
      }
      .buttonStyle(.borderless)
      .font(.caption)
      if showsMessages { messages }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private var messages: some View {
    if action.ownerMessages.isEmpty {
      Text("None: the job had no message from you.")
    }
    ForEach(action.ownerMessages) { message in
      Text(message.fromAutomation ? "Automation: \(message.text)" : message.text)
        .textSelection(.enabled)
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 2) }
    }
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      if decision.sending { ProgressView().controlSize(.small) }
      Button("Decline") {
        if decision.declining {
          model.declineHeldAction(action.id)
        } else {
          model.heldActionBoard.decisions[action.id, default: HeldActionDecision()].declining = true
        }
      }
      if !decision.declining {
        Button("Approve") { model.approveHeldAction(action.id) }
          .buttonStyle(.borderedProminent)
      }
    }
    .disabled(decision.sending)
  }
}
