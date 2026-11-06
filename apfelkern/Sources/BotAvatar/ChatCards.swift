import apfelkern
import SwiftUI

/// A failed job in the chat; opens the job.
public struct JobFailureCard: View {
  let failure: JobFailure
  let open: () -> Void

  public init(failure: JobFailure, open: @escaping () -> Void) {
    self.failure = failure
    self.open = open
  }

  public var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Image(systemName: failure.kind.icon).font(.callout).foregroundStyle(.red)
        Text(failure.title).font(.callout).multilineTextAlignment(.leading)
        Spacer(minLength: 12)
        Image(systemName: "chevron.right").font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: 340, alignment: .leading)
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
      .contentShape(.rect(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .help("Open \(failure.kind.noun)")
    .accessibilityHint("Opens the job")
  }
}

/// "Sent from Discord", under an owner message that came through a message gateway.
public struct GatewayOriginLabel: View {
  let id: String

  public init(id: String) {
    self.id = id
  }

  public var body: some View {
    HStack(spacing: 4) {
      BrandLogoView(.gateway(id), size: 12)
      Text("Sent from \(gatewayLabel(id))")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}
