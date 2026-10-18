import AppKit
import SwiftUI
import Testing
@testable import Crumble

@MainActor
@Suite(.serialized)
struct MentionComposerTests {

    @MainActor
    @Test func mentionQueryFindsNamesWithoutTreatingEmailAddressesAsMentions() {
        let multiword = "Ask @Research Buddy"
        let multiwordMatch = mentionQuery(in: multiword, selection: NSRange(location: (multiword as NSString).length, length: 0))
        #expect(multiwordMatch?.query == "Research Buddy")
        #expect(multiwordMatch?.range == NSRange(location: 4, length: 15))

        let unicode = "Ask @Zoë"
        let unicodeMatch = mentionQuery(in: unicode, selection: NSRange(location: (unicode as NSString).length, length: 0))
        #expect(unicodeMatch?.query == "Zoë")
        #expect(unicodeMatch?.range == NSRange(location: 4, length: 4))

        let email = "mail me@example.com"
        #expect(mentionQuery(in: email, selection: NSRange(location: (email as NSString).length, length: 0)) == nil)
        #expect(mentionQuery(in: multiword, selection: NSRange(location: 7, length: 0))?.query == "Re")
        #expect(mentionQuery(in: multiword, selection: NSRange(location: 3, length: 1)) == nil)
    }

    private func testBot(_ id: String, _ name: String, delegates: [String] = [], tools: [String] = ["delegate"]) -> Agent {
        Agent(id: id, name: name, avatar: "bot:" + id, enabled: true, tools: tools, delegates: delegates)
    }

    @MainActor
    private func hostedComposerWindow(source: Agent, bots: [Agent], model: AppModel) -> NSWindow {
        model.agents = bots
        model.snapshot = ChatSnapshot(status: "idle", agentId: source.id)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Composer(agent: source).environment(model))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @MainActor
    private func press(_ window: NSWindow, characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    @MainActor
    @Test func hostedComposerAcceptsMentionsWithTabAndEnter() async throws {
        _ = NSApplication.shared
        for (keyCode, characters) in [(UInt16(48), "\t"), (UInt16(36), "\r")] {
            let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))
            let target = testBot("bot-2", "Research Buddy")
            let source = testBot("bot-1", "Source", delegates: [target.id])
            let window = hostedComposerWindow(source: source, bots: [source, target], model: model)
            window.isReleasedWhenClosed = false
            try await Task.sleep(for: .milliseconds(300))
            let editor = try #require(window.firstResponder as? NSTextView)

            try await press(window, characters: "Ask @Res", keyCode: 0)
            #expect(model.draft == "Ask @Res")
            try await press(window, characters: characters, keyCode: keyCode)

            #expect(model.draft == "Ask @Research Buddy ")
            #expect(editor.string == "Ask @Research Buddy ")
            #expect(editor.attributedString().attribute(.attachment, at: 4, effectiveRange: nil) == nil)
            #expect(model.sending == false)
            window.close()
        }
    }

    @MainActor
    @Test func hostedComposerNavigatesAndDismissesOnlyPermittedBots() async throws {
        _ = NSApplication.shared
        let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))
        let atlas = testBot("atlas", "Atlas")
        let buddy = testBot("buddy", "Buddy")
        let excluded = testBot("excluded", "Excluded")
        var paused = testBot("paused", "Paused")
        paused.enabled = false
        let source = testBot("source", "Source", delegates: [atlas.id, buddy.id, paused.id])
        let window = hostedComposerWindow(source: source, bots: [source, atlas, buddy, excluded, paused], model: model)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        _ = try #require(window.firstResponder as? NSTextView)
        try await press(window, characters: "Ask @", keyCode: 0)
        let completion = MentionCompletion.find(in: model.draft, selection: NSRange(location: 5, length: 0), bots: [atlas, buddy])
        #expect(completion?.bots.map(\.id) == [atlas.id, buddy.id])
        try await press(window, characters: "\u{f701}", keyCode: 125)
        try await press(window, characters: "\r", keyCode: 36)
        #expect(model.draft == "Ask @Buddy ")
        try await press(window, characters: "and @At", keyCode: 0)
        try await press(window, characters: "\u{1b}", keyCode: 53)
        #expect(model.draft == "Ask @Buddy and @At")
    }
}

private extension NSView {
    func descendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in subviews {
            if let match = child.descendant(of: type) { return match }
        }
        return nil
    }
}
