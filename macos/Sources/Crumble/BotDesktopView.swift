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
                Text(session.controlLabel ?? "")
                    .foregroundStyle(.secondary)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                    .help("Reconnect")
                    .disabled(session.connecting)
            }
            ToolbarItem(placement: .primaryAction) { controlButton }
        }
        .onAppear { session.connect() }
        .onDisappear { session.leave() }
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

/// A small live view of a bot's desktop that opens the full one; a sleeping desktop wakes on request.
struct BotDesktopPreviewCard: View {
    @State var preview: BotDesktopPreview
    let open: () -> Void

    private var status: String {
        if !preview.live { return "Asleep" }
        if preview.link != nil { return "Awake" }
        return preview.error.isEmpty ? "Waking…" : "Unavailable"
    }

    /// A row like the panel's others: name and state, with a small thumbnail of the screen at the end.
    var body: some View {
        Button(action: preview.live ? open : preview.wake) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bot’s desktop").font(.system(size: 13, weight: .medium))
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                thumbnail
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(preview.live ? "Open the bot desktop" : "Wake the bot desktop")
        .accessibilityLabel(preview.live ? "Open the bot desktop" : "Wake the bot desktop")
        .card()
        .onAppear { preview.start() }
        .onDisappear { preview.stop() }
        // The viewer's connection ends while the Mac sleeps, and its link can't reconnect.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            preview.reconnect()
        }
    }

    private var thumbnail: some View {
        ZStack {
            if preview.live, let link = preview.link {
                Color.black
                DesktopWebView(url: link, interactive: false)
            } else if preview.live, preview.error.isEmpty {
                Palette.bubble
                ProgressView().controlSize(.mini)
            } else {
                Palette.bubble
                Image(systemName: preview.live ? "exclamationmark.triangle" : "moon.zzz")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 40)
        .clipShape(.rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .help(preview.error)
    }
}

/// The viewer page; links are single-use, so a new URL is the only reason to load again.
private struct DesktopWebView: NSViewRepresentable {
    let url: URL
    var interactive = true

    final class Coordinator {
        var loaded: URL?
    }

    /// A preview only shows the page, so clicks fall through to the card that opens the full desktop.
    private final class PreviewWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        interactive ? WKWebView() : PreviewWebView()
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
    }
}
