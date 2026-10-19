import SwiftUI
import AppKit

/// The full menu in a small floating panel. Non-activating: no Dock icon, no app switch, and the frontmost
/// app keeps focus until you click into the panel.
@MainActor final class PopoutController: NSObject, NSWindowDelegate {
    static let shared = PopoutController()

    private var window: NSPanel?
    private var tick: Timer?

    /// Content width range. The harbor and cards are laid out for roughly the menu's width, so a very wide or
    /// very narrow panel only stretches or clips them.
    private static let widths: ClosedRange<CGFloat> = 340...420
    private static let minHeight: CGFloat = 360

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
        w.contentMinSize = NSSize(width: Self.widths.lowerBound, height: Self.minHeight)
        w.contentMaxSize = NSSize(width: Self.widths.upperBound, height: .greatestFiniteMagnitude)
        if !w.setFrameUsingName("AnchorPopoutPanel") { w.center() }
        w.setFrameAutosaveName("AnchorPopoutPanel")
        w.setFrame(w.frameRect(forContentRect: clamped(w.contentRect(forFrameRect: w.frame))), display: false)   // saved frames from older builds
        window = w
        w.orderFrontRegardless()
        // A pinned panel is a dashboard: keep it at most a minute old even on a slower interval.
        // Manual-only (0) stays manual.
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { if model.config.refreshSeconds != 0 { model.refreshIfStale() } }
        }
    }

    func close() { window?.close() }

    private func clamped(_ r: NSRect) -> NSRect {
        var r = r
        r.size.width = min(Self.widths.upperBound, max(Self.widths.lowerBound, r.width))
        r.size.height = max(Self.minHeight, r.height)
        return r
    }

    /// contentMin/MaxSize alone isn't always honored by the hosting view, so clamp every live resize too.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        return sender.frameRect(forContentRect: clamped(content)).size
    }

    func windowWillClose(_ notification: Notification) {
        tick?.invalidate(); tick = nil
        window?.delegate = nil
        window = nil
    }
}
