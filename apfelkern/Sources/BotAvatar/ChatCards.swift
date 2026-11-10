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

/// "Sent from Discord" or "Spoken on a call", under an owner message that came through a gateway.
public struct GatewayOriginLabel: View {
  let id: String

  public init(id: String) {
    self.id = id
  }

  public var body: some View {
    HStack(spacing: 4) {
      if id == voiceGatewayID {
        Image(systemName: "phone").font(.system(size: 10))
      } else {
        BrandLogoView(.gateway(id), size: 12)
      }
      Text(gatewayOrigin(id))
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}

/// A centered phone marker for a call's start or end, with the greeting of a call the bot placed under it.
public struct CallMarkerView: View {
  let title: String
  let quote: String?
  let reactions: [String]

  public init(marker: CallMarker, botName: String, reactions: [String] = []) {
    title = marker.title(botName: botName)
    quote = marker.quote
    self.reactions = reactions
  }

  public var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "phone").font(.caption)
        Text(title)
        if !reactions.isEmpty {
          Text(reactions.joined())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .accessibilityLabel("Reacted \(reactions.joined(separator: " "))")
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .accessibilityElement(children: .combine)
      if let quote {
        HStack(spacing: 8) {
          Capsule().fill(.quaternary).frame(width: 2)
          Text(quote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 448, alignment: .leading)
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
  }
}
