import AppKit
import SwiftUI
import Testing
@testable import Crumble

extension MentionComposerTests {
/// Drives the real composer with keyboard events.
@MainActor @Test func shiftReturnBreaksTheLineInsteadOfSending() async throws {
    _ = NSApplication.shared
    let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))
    let agent = Agent(id: "a1", name: "Atlas")
    model.snapshot = ChatSnapshot(status: "idle", agentId: "a1")
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: Composer(agent: agent).environment(model))
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(400))

    func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    try await press("a", keyCode: 0)
    try await press("b", keyCode: 11)
    #expect(model.draft == "ab")
    try await press("\r", keyCode: 36, .shift)
    #expect(model.draft == "ab\n")
    #expect(!model.sending)
}
}
