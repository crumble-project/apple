import apfelkern
import SwiftUI
import UIKit
import WebKit

/// The bot whose bot desktop covers the screen.
struct BotDesktopTarget: Identifiable, Hashable {
  let id: String
}

/// A bot's bot desktop over the whole screen, so edge swipes and drags reach the desktop instead of navigation. Viewer
/// page touches are mouse input: noVNC turns a tap into a click and two-finger drags into scrolling.
struct BotDesktopView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let agentID: String

  var body: some View {
    NavigationStack {
      Group {
        if let client = model.client {
          BotDesktopContent(session: BotDesktopSession(agentID: agentID, client: client))
            .id(agentID)
        } else {
          ContentUnavailableView("Not Connected", systemImage: "display")
        }
      }
      .navigationTitle(model.agents.first { $0.id == agentID }?.name ?? "Bot Desktop")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

private struct BotDesktopContent: View {
  @Environment(\.scenePhase) private var scenePhase
  @State var session: BotDesktopSession
  @State private var keyboard = DesktopKeyboard()
  @State private var typing = false
  @State private var backgroundTask = UIBackgroundTaskIdentifier.invalid

  private var owner: Bool { session.controlKnown && session.holder == .owner }

  var body: some View {
    viewer
      .environment(\.colorScheme, .dark)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { Color.black }
      .navigationSubtitle(session.controlLabel ?? "Bot Desktop")
      .overlay(alignment: .top) {
        if session.link != nil, !session.error.isEmpty {
          Label(session.error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(.red.opacity(0.15)), in: .capsule)
            .padding(.top, 8)
            .padding(.horizontal, 16)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if owner {
          VStack(spacing: 0) {
            if typing { DesktopKeyboardBar(keyboard: keyboard, typing: $typing) }
            hint
          }
          .background(.bar)
        }
      }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
            .disabled(session.connecting)
        }
        if owner, session.link != nil {
          ToolbarItem(placement: .bottomBar) {
            Button("Keyboard", systemImage: "keyboard") { typing.toggle() }
          }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { controlButton }
      }
      .onAppear { session.connect() }
      .onDisappear { session.leave() }
      .onChange(of: scenePhase) { old, new in
        if new == .background {
          leaveForBackground()
        } else if old == .background {
          // iOS closes the viewer's connection in the background, and its link can't reconnect.
          session.connect()
        }
      }
      .onChange(of: owner) { _, owner in
        if !owner { typing = false }
      }
  }

  /// onDisappear doesn't run when the app goes to the background or iOS ends it there, so control would stay behind.
  private func leaveForBackground() {
    session.leave()
    if backgroundTask == .invalid {
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Hand back bot desktop control") {
        Task { @MainActor in finishHandBack() }
      }
    }
    Task {
      await session.settle()
      finishHandBack()
    }
  }

  private func finishHandBack() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  @ViewBuilder private var viewer: some View {
    if let link = session.link {
      DesktopWebView(url: link, keyboard: keyboard)
    } else if !session.error.isEmpty {
      ContentUnavailableView {
        Label("Can't Show the Bot Desktop", systemImage: "display")
      } description: {
        Text(session.error)
      } actions: {
        Button("Try Again") { session.reconnect() }
          .disabled(session.connecting)
      }
    } else {
      ProgressView("Connecting")
    }
  }

  private var hint: some View {
    Text(
      """
      The bot's desktop job waits while you have control. Hand back when you're done. Tap to click, \
      drag to select, touch and hold to right-click, and drag with two fingers to scroll.
      """
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  @ViewBuilder private var controlButton: some View {
    switch session.action {
    case .take:
      Button("Take Control") { session.take() }
        .disabled(session.link == nil)
    case .handBack:
      Button("Hand Back") { session.handBack() }
    case .waiting:
      ProgressView().controlSize(.small)
    }
  }
}

/// A field for what to type on the bot desktop, and the keys the iOS keyboard doesn't have. Text goes over when sent,
/// so autocorrection and dictation have finished with it.
private struct DesktopKeyboardBar: View {
  let keyboard: DesktopKeyboard
  @Binding var typing: Bool
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        TextField("Type on the bot desktop", text: $text)
          .textFieldStyle(.roundedBorder)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.send)
          .focused($focused)
          .onSubmit(send)
        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
          .labelStyle(.iconOnly)
          .font(.title2)
          .disabled(text.isEmpty)
        Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") { typing = false }
          .labelStyle(.iconOnly)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(DesktopKeyboard.Key.allCases) { key in
            Button {
              keyboard.press(key)
            } label: {
              key.label.frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.bordered)
          }
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .onAppear { focused = true }
  }

  private func send() {
    if text.isEmpty {
      keyboard.press(.enter)
    } else {
      keyboard.type(text)
      text = ""
    }
    focused = true
  }
}

extension DesktopKeyboard.Key {
  @ViewBuilder fileprivate var label: some View {
    switch self {
    case .escape: Text("Esc")
    case .tab: Text("Tab")
    case .arrowLeft: Image(systemName: "arrow.left").accessibilityLabel("Left")
    case .arrowUp: Image(systemName: "arrow.up").accessibilityLabel("Up")
    case .arrowDown: Image(systemName: "arrow.down").accessibilityLabel("Down")
    case .arrowRight: Image(systemName: "arrow.right").accessibilityLabel("Right")
    case .enter: Image(systemName: "return").accessibilityLabel("Return")
    case .backspace: Image(systemName: "delete.left").accessibilityLabel("Delete")
    }
  }
}

/// A small live view of a bot's desktop that opens the full one; a sleeping desktop wakes on request.
struct BotDesktopPreviewCard: View {
  @Environment(\.scenePhase) private var scenePhase
  @State var preview: BotDesktopPreview
  let open: () -> Void

  var body: some View {
    // A ZStack, because a Group would apply onDisappear to each branch and stop the preview as it wakes.
    ZStack {
      if preview.live {
        Button(action: open) { live }
        .accessibilityLabel("Open the bot desktop")
      } else {
        Button(action: preview.wake) {
          VStack(spacing: 6) {
            Image(systemName: "zzz")
            Text("Sleeping").font(.subheadline)
            Text("Tap to wake").font(.caption).opacity(0.65)
          }
          .foregroundStyle(.white.opacity(0.7))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(.rect)
        }
        .accessibilityLabel("Wake the bot desktop")
      }
    }
    .buttonStyle(.plain)
    .aspectRatio(16 / 9, contentMode: .fit)
    .background(.black)
    .clipShape(.rect(cornerRadius: 10))
    .onAppear { preview.start() }
    .onDisappear { preview.stop() }
    .onChange(of: scenePhase) { old, _ in
      if old == .background { preview.reconnect() }
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
        ProgressView().tint(.white)
      }
    }
  }
}

/// The viewer page; links are single-use, so a new URL is the only reason to load again.
private struct DesktopWebView: UIViewRepresentable {
  /// The page fits a desktop browser window, so it needs a viewport to fill the phone, and touch must stay with noVNC.
  private static let fitPhone = """
    const viewport = document.createElement("meta");
    viewport.name = "viewport";
    viewport.content = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no";
    document.head.append(viewport);
    const style = document.createElement("style");
    style.textContent = `#screen, #screen * {
      touch-action: none; -webkit-user-select: none; -webkit-touch-callout: none;
    }`;
    document.head.append(style);
    """

  let url: URL
  var keyboard: DesktopKeyboard?
  var interactive = true

  final class Coordinator {
    var loaded: URL?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(
      WKUserScript(source: Self.fitPhone, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.isOpaque = false
    view.backgroundColor = .black
    view.scrollView.backgroundColor = .black
    view.scrollView.isScrollEnabled = false
    view.scrollView.bounces = false
    view.scrollView.pinchGestureRecognizer?.isEnabled = false
    view.scrollView.contentInsetAdjustmentBehavior = .never
    view.isUserInteractionEnabled = interactive
    view.isAccessibilityElement = true
    view.accessibilityLabel = "Bot desktop"
    keyboard?.webView = view
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    guard context.coordinator.loaded != url else { return }
    context.coordinator.loaded = url
    view.load(URLRequest(url: url))
  }
}
