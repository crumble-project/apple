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

    var body: some View {
        // A ZStack, because a Group would apply onDisappear to each branch and stop the preview as it wakes.
        ZStack {
            if preview.live {
                Button(action: open) { live }
                    .help("Open the bot desktop")
                    .accessibilityLabel("Open the bot desktop")
            } else {
                Button(action: preview.wake) {
                    VStack(spacing: 6) {
                        Image(systemName: "zzz")
                        Text("Sleeping").font(.callout)
                        Text("Click to wake").font(.caption).opacity(0.65)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                }
                .help("Wake the bot desktop")
                .accessibilityLabel("Wake the bot desktop")
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(.black)
        .clipShape(.rect(cornerRadius: 10))
        .onAppear { preview.start() }
        .onDisappear { preview.stop() }
        // The viewer's connection ends while the Mac sleeps, and its link can't reconnect.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            preview.reconnect()
        }
    }

    private var live: some View {
        ZStack {
            Color.black
            if let link = preview.link {
                DesktopWebView(url: link, interactive: false)
            } else if !preview.error.isEmpty {
                Text(preview.error)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(12)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .contentShape(.rect)
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
