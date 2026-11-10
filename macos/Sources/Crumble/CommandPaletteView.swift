import apfelkern
import BotAvatar
import SwiftUI

/// Opens the main window, where the palette lives, from anywhere in the app.
struct CommandPaletteButton: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// A palette opened under one of these sheets couldn't be seen or typed in.
    private var mainWindowHasSheet: Bool {
        let secrets = model.botSecretBoard
        return model.agentDraft != nil || model.groupDraft != nil || model.jobSheet != nil
            || secrets.draft != nil || secrets.useLog != nil
    }

    var body: some View {
        Button("Search…") {
            openWindow(id: "main")
            model.commandPaletteOpen.toggle()
        }
        .disabled(mainWindowHasSheet)
    }
}

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var selection: PaletteItem.ID?
    @FocusState private var searching: Bool

    private var sections: [PaletteSection] { model.commandPalette.matching(query) }

    var body: some View {
        let sections = sections
        let items = sections.flatMap(\.items)
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .onTapGesture { close() }
            VStack(spacing: 0) {
                TextField("Search chats, pages, and settings", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(14)
                    .focused($searching)
                    .onSubmit { if let item = chosen(in: items) { run(item) } }
                    .onKeyPress(.upArrow) { move(-1, in: items) }
                    .onKeyPress(.downArrow) { move(1, in: items) }
                    .onExitCommand { close() }
                Divider()
                results(sections)
            }
            .frame(width: 560, height: 420)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial).shadow(radius: 24, y: 8)
            }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
            .padding(.top, 48)
        }
        .onAppear { searching = true }
        .onChange(of: query) { selection = nil }
    }

    @ViewBuilder private func results(_ sections: [PaletteSection]) -> some View {
        if sections.isEmpty {
            Text("No results").foregroundStyle(.secondary).frame(maxHeight: .infinity)
        } else {
            let chosenID = selection ?? sections.first?.items.first?.id
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(section.items) { item in
                                row(item, isChosen: item.id == chosenID).id(item.id)
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ item: PaletteItem, isChosen: Bool) -> some View {
        Button { run(item) } label: {
            HStack(spacing: 10) {
                if case .open(.agent(let id)) = item.command, let agent = model.agents.first(where: { $0.id == id }) {
                    BotAvatarView(agent: agent, size: 20, state: model.botState(agent))
                } else {
                    Image(systemName: item.symbol).frame(width: 20)
                }
                Text(item.title).lineLimit(1)
                Spacer(minLength: 0)
                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(isChosen ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func chosen(in items: [PaletteItem]) -> PaletteItem? {
        items.first { $0.id == selection } ?? items.first
    }

    private func move(_ step: Int, in items: [PaletteItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .handled }
        let current = chosen(in: items).flatMap(items.firstIndex(of:)) ?? 0
        selection = items[(current + step + items.count) % items.count].id
        return .handled
    }

    private func close() { model.commandPaletteOpen = false }

    private func run(_ item: PaletteItem) {
        close()
        switch item.command {
        case .open(let route):
            switch route {
            case .agent, .group: model.navigate(to: route)
            default: openSettings(.page(route))
            }
        case .settings: openSettings(.general)
        case .newBot: model.createAgent()
        case .newGroupChat: model.createGroup()
        case .theme(let theme): model.chooseTheme(theme)
        }
    }

    private func openSettings(_ target: SettingsTarget) {
        model.settingsTarget = target
        openWindow(id: SettingsButton.windowID)
    }
}
