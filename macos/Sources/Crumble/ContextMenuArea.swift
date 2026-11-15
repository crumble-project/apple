import AppKit
import SwiftUI

/// A right-click menu that reports while it's open, which SwiftUI's `.contextMenu` doesn't, so a view
/// can mark what the menu acts on. It takes right-clicks only; other clicks reach the views below.
struct ContextMenuArea: NSViewRepresentable {
    struct Item {
        let title: String
        var enabled = true
        let action: () -> Void
    }

    let items: [Item]
    @Binding var isOpen: Bool

    func makeNSView(context: Context) -> MenuView { MenuView() }

    func updateNSView(_ view: MenuView, context: Context) {
        view.items = items
        view.onOpenChange = { open in isOpen = open }
    }

    final class MenuView: NSView {
        var items: [Item] = []
        var onOpenChange: (Bool) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let controlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
            guard event.type == .rightMouseDown || controlClick else { return nil }
            return super.hitTest(point)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                let entry = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
                entry.target = self
                entry.isEnabled = item.enabled
                entry.representedObject = item.action
                menu.addItem(entry)
            }
            return menu
        }

        @objc private func choose(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }

        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { onOpenChange(true) }

        override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) { onOpenChange(false) }
    }
}
