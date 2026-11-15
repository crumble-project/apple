import apfelkern
import AppKit
import SwiftUI
import Testing

@testable import Crumble

extension MentionComposerTests {
    @MainActor @Test func returnWaitsForReadinessWithoutBlockingTheDraft() async throws {
        _ = NSApplication.shared
        let (client, _) = ControlledDeliveryProtocol.client()
        let model = AppModel(client: client)
        model.draft = "Draft"
        var sends = 0
        let target = ComposerTarget(
            placeholder: "Message", enabled: true, mentionable: [], running: false, stopHelp: "Stop",
            send: { sends += 1 }, stop: {})
        let view = NSHostingView(rootView: Composer(target: target, ready: false).environment(model))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let editor = window.firstResponder as? NSTextView
        try #require(editor != nil)
        try pressReturn(in: window)
        #expect(sends == 0)
        #expect(model.draft == "Draft")
        view.rootView = Composer(target: target, ready: true).environment(model)
        try await Task.sleep(for: .milliseconds(100))
        try pressReturn(in: window)
        #expect(sends == 1)
    }

    @MainActor private func pressReturn(in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
            window.sendEvent(event)
        }
    }
}
