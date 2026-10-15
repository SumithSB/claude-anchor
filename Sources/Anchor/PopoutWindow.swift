import SwiftUI
import AppKit

/// The full menu in a small floating panel. Non-activating: no Dock icon, no app switch, and the frontmost
/// app keeps focus until you click into the panel.
@MainActor final class PopoutController: NSObject, NSWindowDelegate {
    static let shared = PopoutController()

    private var window: NSPanel?

    func show(_ model: AppModel) {
        if let w = window { w.orderFrontRegardless(); return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.title = "Claude Anchor"
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.delegate = self
        let host = NSHostingView(rootView: PopoverView(popout: true).environment(model))
        host.sizingOptions = []   // the window, not the content, decides the size
        w.contentView = host
        w.contentMinSize = NSSize(width: 340, height: 360)
        if !w.setFrameUsingName("AnchorPopoutPanel") { w.center() }
        w.setFrameAutosaveName("AnchorPopoutPanel")
        window = w
        w.orderFrontRegardless()
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
    }
}
