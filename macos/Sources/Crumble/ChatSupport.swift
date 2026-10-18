import AppKit
import SwiftUI

extension View {
    /// The bubble a message sits in: the accent color for the owner, a quiet gray otherwise.
    func bubble(owner: Bool) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(owner ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(
                owner ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.07)), in: .rect(cornerRadius: 18))
    }
}
