import apfelkern
import SwiftUI
import WebKit

/// A bot's bot desktop in its own window: the server's viewer page, with control around it.
struct BotDesktopView: View {
    static let windowID = "bot-desktop"

    @Environment(AppModel.self) private var model
    let agentID: String

    var body: some View {
        if let client = model.client {
            BotDesktopContent(session: BotDesktopSession(agentID: agentID, client: client))
                .id(agentID)
                .navigationTitle(model.agents.first { $0.id == agentID }?.name ?? "Bot Desktop")
                .navigationSubtitle("Bot Desktop")
        } else {
            ContentUnavailableView("Not Connected", systemImage: JobKind.desktop.icon)
        }
    }
}

private struct BotDesktopContent: View {
    @State var session: BotDesktopSession

    var body: some View {
        Group {
            if let link = session.link {
                DesktopWebView(url: link)
            } else if !session.error.isEmpty {
                ContentUnavailableView {
                    Label("Can't Show the Bot Desktop", systemImage: JobKind.desktop.icon)
                } description: {
                    Text(session.error)
                }
            } else {
                ProgressView("Connecting")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .overlay(alignment: .top) {
            if session.link != nil, !session.error.isEmpty {
                Label(session.error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(.red.opacity(0.15)), in: .capsule)
                    .padding(.top, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                Text(session.holder == .owner ? "You have control" : "The bot has control")
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                    .help("Reconnect")
            }
            ToolbarItem(placement: .primaryAction) { controlButton }
        }
        .onAppear { session.connect() }
        // Control left with a closed window would keep the bot's job paused with nobody watching.
        .onDisappear {
            if session.holder == .owner { session.handBack() }
            session.close()
        }
    }

    @ViewBuilder private var controlButton: some View {
        switch session.action {
        case .take:
            Button("Take Control", systemImage: "hand.raised") { session.take() }
        case .handBack:
            Button("Hand Back", systemImage: "arrow.uturn.backward") { session.handBack() }
        case .waiting:
            ProgressView().controlSize(.small)
        }
    }
}

/// The viewer page; links are single-use, so a new URL is the only reason to load again.
private struct DesktopWebView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loaded: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
    }
}
