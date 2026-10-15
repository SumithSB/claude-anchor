import SwiftUI
import AppKit

/// The full menu in a standalone, resizable window. The app is an agent (LSUIElement), so while the window is
/// open it becomes a regular app (Dock icon, Cmd-Tab, proper focus) and goes back to accessory on close.
@MainActor final class PopoutController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = PopoutController()

    private static let pinID = NSToolbarItem.Identifier("anchor.pin")
    private var window: NSWindow?
    private var pinItem: NSToolbarItem?
    private var pinned = false

    func show(_ model: AppModel) {
        if let w = window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Claude Anchor"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let host = NSHostingView(rootView: PopoverView(popout: true).environment(model))
        host.sizingOptions = []   // the window, not the content, decides the size
        w.contentView = host
        w.contentMinSize = NSSize(width: 340, height: 360)
        if !w.setFrameUsingName("AnchorPopout") { w.center() }
        w.setFrameAutosaveName("AnchorPopout")
        w.level = pinned ? .floating : .normal

        let tb = NSToolbar(identifier: "anchor.popout")
        tb.delegate = self
        tb.displayMode = .iconOnly
        w.toolbar = tb

        window = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    // MARK: pin

    @objc private func togglePin() {
        pinned.toggle()
        window?.level = pinned ? .floating : .normal
        updatePinItem()
    }

    private func updatePinItem() {
        pinItem?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Keep on top")
        pinItem?.toolTip = pinned ? "Keep on top: on" : "Keep on top"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.pinID] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.pinID] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.pinID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Keep on top"
        item.paletteLabel = "Keep on top"
        item.target = self
        item.action = #selector(togglePin)
        pinItem = item
        updatePinItem()
        return item
    }

    // MARK: delegate

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window?.toolbar = nil
        window = nil
        pinItem = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
