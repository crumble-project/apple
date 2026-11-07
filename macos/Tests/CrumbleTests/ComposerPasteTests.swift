import AppKit
import Foundation
import Testing
import apfelkern

@testable import Crumble

/// A private pasteboard, so the tests leave the owner's clipboard alone.
@MainActor private func pasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("crumble-test-\(UUID().uuidString)"))
    board.clearContents()
    return board
}

@MainActor private func pngData() throws -> Data {
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor
struct ComposerPasteTests {
    private let model = AppModel(client: APIClient(baseURL: "http://127.0.0.1:1", token: ""))

    @Test func anImageAttachesAndKeepsItsType() throws {
        let board = pasteboard()
        board.setData(try pngData(), forType: .png)
        #expect(model.pasteAttachments(from: board))
        #expect(model.attachments.map(\.name) == ["Pasted image.png"])
        #expect(model.attachments.map(\.mimeType) == ["image/png"])
    }

    @Test func aFileAttachesUnderItsOwnName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("made-up".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let board = pasteboard()
        board.writeObjects([url as NSURL])
        #expect(model.pasteAttachments(from: board))
        #expect(model.attachments.map(\.name) == [url.lastPathComponent])
    }

    @Test func onlyCommandVPastes() throws {
        let press = { (modifiers: NSEvent.ModifierFlags, key: String) in
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 9))
        }
        #expect(PasteMonitor.isPaste(try press(.command, "v")))
        #expect(!PasteMonitor.isPaste(try press([], "v")))
        #expect(!PasteMonitor.isPaste(try press([.command, .shift], "v")))
        #expect(!PasteMonitor.isPaste(try press(.command, "c")))
    }

    @Test func textStaysForTheField() {
        let board = pasteboard()
        board.setString("hello", forType: .string)
        #expect(!model.pasteAttachments(from: board))
        #expect(model.attachments.isEmpty)
    }
}
