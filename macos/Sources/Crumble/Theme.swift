import apfelkern
import BotAvatar
import SwiftUI

/// Layout and type for the chat. Colors come from the system so the app follows its appearance
/// and accent color.
enum Palette {
    /// The transcript and composer share one readable column, however wide the window is.
    static let column: CGFloat = 820
    /// Message text sits a little larger than the system body size, with room between lines.
    static let messageFont = Font.system(size: 14.5)
    static let messageLineSpacing: CGFloat = 4
    /// The bot's side of the conversation: a quiet gray that works in light and dark.
    static let bubble = Color.primary.opacity(0.07)
}

extension Agent {
    /// The body color of the bot's avatar, for touches that should feel like the bot.
    var color: Color {
        let value = UInt32(BotLook(seed: agentAvatarSeed(self)).hex.dropFirst(), radix: 16) ?? 0
        return Color(
            red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// A pixel-art glow in the bot's color hanging from the top edge, quantized into a few tones with
/// the same 4×4 ordered dither the avatars use. Its lower edge is an arch: deepest at the sides and
/// rising to `peak` points in the middle, so whatever sits there stays clear.
struct DitherGlow: View {
    let color: Color
    var peak: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private static let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    var body: some View {
        let tones: [Double] = colorScheme == .dark ? [0, 0.08, 0.16, 0.28] : [0, 0.07, 0.14, 0.24]
        Canvas { context, size in
            let cell: CGFloat = 4
            var paths = Array(repeating: Path(), count: tones.count)
            for column in 0..<Int((size.width / cell).rounded(.up)) {
                let x = CGFloat(column) * cell
                let across = min(abs(x + cell / 2 - size.width / 2) / (size.width / 2), 1)
                let depth = size.height - (size.height - peak) * sqrt(1 - across * across)
                for row in 0..<Int((depth / cell).rounded(.up)) {
                    let y = CGFloat(row) * cell
                    let level = pow(max(1 - (y + cell / 2) / depth, 0), 1.4) * Double(tones.count - 1)
                    let threshold = (Self.bayer[row % 4][column % 4] + 0.5) / 16
                    let tone = min(Int(level) + (level - level.rounded(.down) > threshold ? 1 : 0), tones.count - 1)
                    if tone > 0 { paths[tone].addRect(CGRect(x: x, y: y, width: cell, height: cell)) }
                }
            }
            for (tone, path) in paths.enumerated() where tone > 0 {
                context.fill(path, with: .color(color.opacity(tones[tone])))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
