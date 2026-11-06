import apfelkern
import SwiftUI

public struct FilterPill<Value: Hashable>: Identifiable {
  public let value: Value
  public let label: String
  public var count: Int?
  public var symbol: String?
  public var avatar: BotAvatarDefinition?

  public var id: Value { value }

  public init(
    value: Value, label: String, count: Int? = nil, symbol: String? = nil, avatar: BotAvatarDefinition? = nil
  ) {
    self.value = value
    self.label = label
    self.count = count
    self.symbol = symbol
    self.avatar = avatar
  }
}

/// One choice out of a scrolling row, as the web's filter pills.
public struct FilterPills<Value: Hashable>: View {
  let label: String
  let pills: [FilterPill<Value>]
  @Binding var selection: Value

  public init(label: String, pills: [FilterPill<Value>], selection: Binding<Value>) {
    self.label = label
    self.pills = pills
    _selection = selection
  }

  public var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(pills) { pill in
          let selected = pill.value == selection
          Button { selection = pill.value } label: { content(pill) }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
              selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.5)),
              in: .capsule)
            .accessibilityLabel(pill.count.map { "\(pill.label), \($0)" } ?? pill.label)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }

  private func content(_ pill: FilterPill<Value>) -> some View {
    HStack(spacing: 4) {
      if let avatar = pill.avatar {
        BotAvatarView(avatar: avatar, size: 18)
      } else if let symbol = pill.symbol {
        Image(systemName: symbol).imageScale(.small)
      }
      Text(pill.label).lineLimit(1)
      if let count = pill.count {
        Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit()
      }
    }
    .font(.subheadline)
    .contentShape(.capsule)
  }
}
