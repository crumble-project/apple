import apfelkern
import BotAvatar
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        // The system sidebar list: its own selection and arrow keys.
        List(selection: Binding(get: { model.route }, set: { model.navigate(to: $0) })) {
            // One list: a group's stacked avatars already set it apart from a bot.
            Section {
                ForEach(model.unpinnedAgents) { agent in
                    AgentRow(agent: agent)
                        .tag(Route.agent(agent.id))
                        .disabled(model.pendingMutations.contains("agent:\(agent.id)"))
                }
                ForEach(model.unpinnedGroups) { group in
                    GroupRow(group: group)
                        .tag(Route.group(group.id))
                        .disabled(model.pendingMutations.contains("group:\(group.id)") || group.id.hasPrefix("local:"))
                }
            }
        }
        .listStyle(.sidebar)
        // Above the list, not a row in it: the list outlines a whole row on right-click, which
        // would take in every pin. So the pins stay put while the conversations scroll.
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.pinnedConversations.isEmpty {
                PinnedGrid()
                    .padding(.horizontal, 10)
                    .background(Palette.chrome)
            }
        }
        .focused($focused)
        .onKeyPress(.return) {
            model.focusComposer()
            return .handled
        }
        .onChange(of: focused, initial: true) { _, focused in model.sidebarFocused = focused }
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .overlay {
            if model.agents.isEmpty && !model.loading {
                Text("No agents yet").foregroundStyle(.secondary)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button("Search", systemImage: "magnifyingglass") { model.commandPaletteOpen = true }
                    .help("Search (⌘K)")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                // A click makes a bot; holding it offers a group chat too.
                Menu {
                    Button("New Agent") { model.createAgent() }
                    Button("New Group Chat") { model.createGroup() }
                        .disabled(model.agents.count < GroupDraft.memberRange.lowerBound)
                } label: {
                    Label("New Agent", systemImage: "plus")
                } primaryAction: {
                    model.createAgent()
                }
                .menuIndicator(.hidden)
                .help("New Agent (⌘N). Hold for a group chat (⇧⌘N).")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountFooter() }
    }
}

/// Who is signed in, how the connection is doing, and the way to Settings.
struct AccountFooter: View {
    @Environment(AppModel.self) private var model

    private var name: String {
        let account = model.serverAccountBoard.account
        return account?.name.nilIfEmpty ?? account?.email.nilIfEmpty ?? "Crumble"
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(initials)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Palette.bubble, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if model.loading || !model.streamStatus.isEmpty { ConnectionStatus() }
            }
            Spacer(minLength: 0)
            SettingsButton()
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: 30, height: 30)
                .help("Settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var hovered = false

    /// A short description reads as a label beside the name; longer ones stay in the profile.
    private var label: String? {
        guard let description = agent.description?.nilIfEmpty, description.count <= 24 else { return nil }
        return description
    }

    var body: some View {
        HStack(spacing: 10) {
            let state = model.botState(agent)
            // Avatars draw on the CPU every frame, so a bot here animates only while it works or is hovered.
            CalmAvatar(agent: agent, size: 44, state: state, active: hovered)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(agent.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !agent.enabled {
                        chip("Paused")
                    } else if let label {
                        chip(label)
                    }
                }
                Text(preview(agent.lastMessage ?? "").nilIfEmpty ?? "No messages yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { PinButton(route: .agent(agent.id)) }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: .rect(cornerRadius: 5))
    }
}
