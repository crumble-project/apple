import apfelkern
import BotAvatar
import SwiftUI

/// The account's pins at the top of the sidebar, like Messages: round portraits with names, three
/// to a row. A click opens the chat, a right-click unpins, and dropping one pin on another moves it there.
struct PinnedGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PinRows(columns: 3, spacing: 2, rowSpacing: 4) {
            ForEach(model.pinnedConversations) { PinnedTile(conversation: $0) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

private struct PinnedTile: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var hovered = false
    @State private var targeted = false
    /// The pin's menu is open, so the tile shows which pin it acts on.
    @State private var menuOpen = false

    private static let size: CGFloat = 60

    private var route: Route { conversation.route }
    private var selected: Bool { model.route == route }
    private var unread: Bool { model.unread.count(route) > 0 }

    private var name: String {
        switch conversation {
        case .bot(let agent): agent.name
        case .group(let group): group.name
        }
    }

    @ViewBuilder private var portrait: some View {
        switch conversation {
        case .bot(let agent):
            CalmAvatar(agent: agent, size: Self.size * 0.68, state: model.botState(agent), active: hovered)
        case .group(let group):
            let members = group.memberIds.compactMap { id in model.agents.first { $0.id == id } }
            ZStack(alignment: .topLeading) {
                ForEach(Array(members.prefix(2).enumerated()), id: \.element.id) { index, agent in
                    BotAvatarView(agent: agent, size: Self.size * 0.46, state: .idle)
                        .offset(x: CGFloat(index) * Self.size * 0.22, y: CGFloat(index) * Self.size * 0.22)
                }
            }
            .frame(width: Self.size * 0.68, height: Self.size * 0.68, alignment: .topLeading)
        }
    }

    private var circle: some View {
        portrait
            .frame(width: Self.size, height: Self.size)
            .background(selected ? Color.white.opacity(0.22) : Palette.bubble, in: .circle)
    }

    var body: some View {
        VStack(spacing: 5) {
            circle
                .overlay {
                    if targeted { Circle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5) }
                }
                .overlay(alignment: .topLeading) {
                    if unread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 11, height: 11)
                            .overlay { Circle().strokeBorder(Palette.chrome, lineWidth: 2) }
                    }
                }
            Text(name)
                .font(.system(size: 11, weight: unread || selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(maxWidth: Self.size + 12)
        }
        // Every tile keeps this padding, so the grid stays put as the selection moves.
        .padding(.horizontal, 6)
        .padding(.top, 7)
        .padding(.bottom, 6)
        // The open chat's pin sits on an accent tile, as in Messages.
        .background {
            if selected { RoundedRectangle(cornerRadius: 10).fill(Color.accentColor) }
        }
        .overlay {
            if menuOpen {
                // On the accent tile, a white line inside keeps the outline visible, as in Messages.
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: 1.5).padding(2) }
            }
        }
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .onTapGesture { model.navigate(to: route) }
        // An AppKit menu, not `.contextMenu`: only AppKit says when the menu opens and closes.
        .overlay {
            ContextMenuArea(
                items: [.init(title: "Unpin", enabled: model.canChangePins) { model.setPinned(route, false) }],
                isOpen: $menuOpen)
        }
        .draggable(PinnedConversations.key(route) ?? "") { circle }
        .dropDestination(for: String.self) { keys, _ in
            guard let dragged = keys.first.flatMap(PinnedConversations.route(key:)), dragged != route,
                model.isPinned(dragged)
            else { return false }
            withAnimation(.snappy) { model.movePin(dragged, to: route) }
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(unread ? "Pinned, Unread" : "Pinned")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.navigate(to: route) }
        .accessibilityAction(named: "Unpin") { model.setPinned(route, false) }
        .help(name)
    }
}

/// Rows of up to `columns` views, each row centered, like Messages' pins.
private struct PinRows: Layout {
    let columns: Int
    let spacing: CGFloat
    let rowSpacing: CGFloat

    private func rows(_ subviews: Subviews) -> [[LayoutSubview]] {
        stride(from: 0, to: subviews.count, by: columns).map {
            Array(subviews[$0..<min($0 + columns, subviews.count)])
        }
    }

    private func rowSize(_ row: [LayoutSubview]) -> CGSize {
        let sizes = row.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = rows(subviews).map(rowSize)
        let height = sizes.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for row in rows(subviews) {
            let size = rowSize(row)
            var leading = bounds.midX - size.width / 2
            for subview in row {
                let fitted = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: leading, y: top), proposal: ProposedViewSize(fitted))
                leading += fitted.width + spacing
            }
            top += size.height + rowSpacing
        }
    }
}
