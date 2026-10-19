import AppKit
import SwiftUI

extension View {
    /// The bubble a message sits in: the accent color for the owner, a quiet gray otherwise.
    func bubble(owner: Bool) -> some View {
        padding(.horizontal, owner ? 14 : 15)
            .padding(.vertical, owner ? 9 : 10)
            .foregroundStyle(owner ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(owner ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.bubble), in: .rect(cornerRadius: 18))
    }
}
