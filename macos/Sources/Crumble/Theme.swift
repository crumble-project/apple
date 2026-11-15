import AppKit
import apfelkern
import BotAvatar
import SwiftUI

/// Layout and type for the chat. Colors come from the system so the app follows its appearance
/// and accent color.
enum Palette {
    /// The transcript and composer share one readable column, however wide the window is.
    static let column: CGFloat = 820
    /// A bot's reply stays narrower than the column so long answers keep a comfortable line length.
    static let bubbleWidth: CGFloat = 620
    /// How far a chat's header reaches below the toolbar, so the first message starts clear of it.
    static let headerOverhang: CGFloat = 32
    /// Message text sits a little larger than the system body size, with room between lines.
    static let messageFont = Font.system(size: 14.5)
    static let messageLineSpacing: CGFloat = 4
    /// The bot's side of the conversation: a quiet gray that works in light and dark.
    static let bubble = Color.primary.opacity(0.06)
    /// The sidebar and the details panel: a step back from the white of the conversation.
    static let chrome = Color(light: NSColor(white: 0.968, alpha: 1), dark: NSColor(white: 0.09, alpha: 1))
    /// Grouped rows, the composer, and other raised surfaces.
    static let card = Color(light: .white, dark: NSColor(white: 0.17, alpha: 1))
    static let hairline = Color.primary.opacity(0.08)
    /// The owner's messages and the send button: near-black in light, near-white in dark.
    static let ink = Color(light: NSColor(white: 0.11, alpha: 1), dark: NSColor(white: 0.92, alpha: 1))
    static let onInk = Color(light: .white, dark: NSColor(white: 0.08, alpha: 1))
}

/// Offers its content at most `limit` points and takes the content's own size, so short content
/// stays short, unlike `frame(maxWidth:)`, which grows to fill whatever it is offered.
struct WidthCap: Layout {
    let limit: CGFloat

    init(_ limit: CGFloat) { self.limit = limit }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { min($0, limit) } ?? limit, height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A blur that deepens toward the top edge, with a wash of the background color for contrast under the
/// toolbar. Without the variable blur, the lightest material, masked to thin out downward, stands in, and a
/// stronger wash hides its gray tint. Reduce Transparency keeps only the wash.
struct ProgressiveBlur: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                wash(top: 0.95, middle: 0.8)
            } else if VariableBlurNSView.isAvailable {
                VariableBlur(maximumRadius: 3)
                wash(top: 0.35, middle: 0.1)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0.4), .init(color: .clear, location: 1)],
                            startPoint: .top, endPoint: .bottom))
                wash(top: 0.85, middle: 0.55)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func wash(top: Double, middle: Double) -> some View {
        let background = Color(nsColor: .textBackgroundColor)
        return LinearGradient(
            stops: [
                .init(color: background.opacity(top), location: 0),
                .init(color: background.opacity(middle), location: 0.5),
                .init(color: background.opacity(0), location: 1)
            ],
            startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
    }
}

extension View {
    /// A transcript scrolls under a header that hangs from the window's top edge, as in Messages,
    /// behind a blur that deepens toward the top so the header stays calm without cutting text off.
    func headerBand(@ViewBuilder header: () -> some View) -> some View {
        scrollEdgeEffectStyle(.soft, for: .bottom)
            .scrollEdgeEffectHidden(true, for: .top)
            .contentMargins(.top, Palette.headerOverhang, for: .scrollContent)
            .overlay(alignment: .top) {
                ProgressiveBlur().frame(height: 65).ignoresSafeArea(edges: .top)
            }
            .overlay(alignment: .top) {
                header().padding(.top, 6).ignoresSafeArea(edges: .top)
            }
    }

    /// A raised surface for grouped content: the card color, a hairline edge, and a faint shadow.
    func card(cornerRadius: CGFloat = 12) -> some View {
        background(Palette.card, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

extension Agent {
    /// The body color of the bot's avatar, for touches that should feel like the bot.
    var color: Color {
        avatar.bodyColor
    }
}

extension AppTheme {
    /// Nil follows the system, and the app's windows follow `NSApp.appearance`.
    fileprivate var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Set on each window that can be alone on screen, since a closed window's view doesn't update.
struct FollowsTheme: ViewModifier {
    let board: ThemeBoard

    func body(content: Content) -> some View {
        content.onChange(of: board.theme, initial: true) { _, theme in NSApp.appearance = theme.appearance }
    }
}

/// A chat's title as Messages draws it: the avatar large and centered at the top of the window, with
/// the name on a pill that overlaps the avatar's lower edge.
struct ChatHeader<Avatar: View>: View {
    let title: String
    let help: String
    let action: () -> Void
    @ViewBuilder let avatar: Avatar

    var body: some View {
        Button(action: action) {
            VStack(spacing: -9) {
                avatar
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.card, in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}
