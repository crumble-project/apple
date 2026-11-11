import AppKit
import SwiftUI

extension View {
    /// The bubble a message sits in: ink for the owner, a quiet gray otherwise.
    func bubble(owner: Bool) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, owner ? 8 : 11)
            .foregroundStyle(owner ? Palette.onInk : Color.primary)
            .background(owner ? Palette.ink : Palette.bubble, in: .rect(cornerRadius: owner ? 17 : 16))
    }
}
