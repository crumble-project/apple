import SwiftUI

extension View {
  /// On a chat's scroll view: a button that returns to the newest message once the owner scrolled away.
  public func jumpToLatest() -> some View {
    modifier(JumpToLatest())
  }
}

private struct JumpToLatest: ViewModifier {
  /// Past a line or two of slack, so the button doesn't flicker while a reply grows.
  private static let threshold: CGFloat = 120

  @State private var position = ScrollPosition()
  @State private var away = false

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY > Self.threshold
      } action: { _, isAway in
        withAnimation(.easeOut(duration: 0.15)) { away = isAway }
      }
      .overlay(alignment: .bottom) {
        if away {
          Button("Jump to Latest", systemImage: "arrow.down") {
            withAnimation { position.scrollTo(edge: .bottom) }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .controlSize(.large)
          .help("Jump to Latest")
          .padding(.bottom, 12)
          .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
      }
  }
}
