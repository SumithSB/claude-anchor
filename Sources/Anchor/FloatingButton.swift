import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: formatting shared by the button, tooltip and quick panel

enum FloatingFormat {
    /// "1h 39m", "22m", "<1m".
    static func countdown(_ date: Date, now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s < 60 { return "<1m" }
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// "resets in 1h 39m" within a day, "resets Fri" further out, "full window" when nothing is counted.
    static func reset(_ w: LimitWindow?, weekly: Bool) -> String {
        guard let w else { return "" }
        guard let d = w.resetsAt, d > Date() else { return w.percent < 1 ? "full window" : "" }
        if weekly && d.timeIntervalSinceNow > 86_400 { return "resets " + d.formatted(.dateTime.weekday(.abbreviated)) }
        return "resets in " + countdown(d)
    }

    @MainActor static func tip(_ model: AppModel) -> String {
        guard let a = model.active else { return "Claude Anchor" }
        var parts = [a.name]
        if let w = model.limits[a.id]?.fiveHour {
            parts.append("5h \(Int(w.percent.rounded()))%")
            if let d = w.resetsAt, d > Date() { parts.append("resets in " + countdown(d)) }
        }
        var s = parts.joined(separator: " · ")
        let fresh = model.freshAccounts.filter { $0.id != a.id }
        if fresh.count == 1 { s += " · \(fresh[0].name) is fresh" } else if fresh.count > 1 { s += " · \(fresh.count) fresh" }
        return s
    }
}

// MARK: the 60pt button

@MainActor struct FloatingButtonView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let acct = model.active
        let pct = acct.flatMap { model.limits[$0.id]?.fiveHour?.percent }
        ZStack {
            Circle().fill(Clay.surface)
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4).padding(5)
            if let p = pct {
                Circle().trim(from: 0, to: max(0.02, min(1, p / 100)))
                    .stroke(Clay.gradient(p), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
            }
            Circle().fill(Clay.accent).frame(width: 36, height: 36)
            AnchorGlyph()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 16)
        }
        .frame(width: 60, height: 60)
        .overlay(Circle().stroke(Clay.hairline, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if let a = acct {
                FlagView(flag: a.flag, size: 10)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Clay.surface))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Clay.hairline, lineWidth: 1))
                    .offset(x: 3, y: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            if !model.freshAccounts.isEmpty {
                Circle().fill(Clay.fresh).frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Clay.surface, lineWidth: 2))
                    .offset(x: 1, y: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if (pct ?? 0) >= 90 {
                Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Clay.limit))
                    .overlay(Circle().stroke(Clay.surface, lineWidth: 2))
                    .offset(x: 2, y: 0)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 7, x: 0, y: 4)
        .frame(width: 72, height: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Anchor")
        .accessibilityValue(FloatingFormat.tip(model))
    }
}

@MainActor struct FloatingTooltipView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Text(FloatingFormat.tip(model))
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(Clay.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
            .padding(12)
    }
}

// MARK: the quick panel's content

@MainActor struct QuickPanelView: View {
    @Environment(AppModel.self) private var model
    var maxHeight: CGFloat?
    var onOpenFull: () -> Void = {}
    var onHide: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        if let maxHeight {
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical, showsIndicators: false) { content }
            }
            .frame(width: 300, height: maxHeight)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(spacing: 10) {
                bar("5-hour", model.active.flatMap { model.limits[$0.id]?.fiveHour }, weekly: false)
                bar("Weekly", model.active.flatMap { model.limits[$0.id]?.weekly }, weekly: true)
            }
            FreshCard(compact: true)
            HarborView(width: 268)
            ContinueCard(compact: true)
            Divider()
            HStack {
                Button(action: onOpenFull) {
                    Text("Open full menu →").font(.system(size: 12, weight: .semibold)).foregroundStyle(Clay.accentText)
                }.buttonStyle(.plain)
                Spacer()
                Button(action: onHide) {
                    Text("Hide button").font(.system(size: 12)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 9) {
            if let a = model.active {
                FlagView(flag: a.flag, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("Default account").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let plan = a.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 10, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Clay.accentText)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(Clay.accent.opacity(0.14)))
                }
            } else {
                Text("Claude Anchor").font(.system(size: 14, weight: .semibold))
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Clay.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Clay.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func bar(_ label: String, _ w: LimitWindow?, weekly: Bool) -> some View {
        let p = w?.percent ?? 0
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text(FloatingFormat.reset(w, weekly: weekly)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(w == nil ? "—" : "\(Int(p.rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(p >= 90 ? Clay.limit : Color.primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Clay.gradient(p)).frame(width: g.size.width * max(0, min(1, p / 100)))
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: AppKit pieces

/// Never takes key or main status, so clicking the button leaves the frontmost app alone.
private final class ButtonPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Becomes key (without activating the app) so Escape reaches it.
private final class QuickPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Owns all mouse input for the button: drag to move, click (under 4pt of travel) to open, hover for the tooltip.
private final class ButtonContainer: NSView {
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var moved = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        startMouse = NSEvent.mouseLocation
        startOrigin = w.frame.origin
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        if !moved {
            if hypot(dx, dy) <= 4 { return }
            moved = true
            onDragStart?()
        }
        w.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if moved { onDragEnd?() } else { onClick?() }
        moved = false
    }
}

private func anchorHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ ctx: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in FloatingController.shared.hotKeyFired() }
    return noErr
}

// MARK: controller

@MainActor final class FloatingController {
    static let shared = FloatingController()

    private static let side: CGFloat = 72      // panel size; the button is 60pt, centred
    private static let edgeMargin: CGFloat = 4  // plus 6pt of transparent padding

    private weak var model: AppModel?
    private var panel: ButtonPanel?
    private var quick: QuickPanel?
    private var tip: NSPanel?
    private var fadeTimer: Timer?
    private var tipTimer: Timer?
    private var hovering = false
    private var dragging = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false

    // MARK: public

    /// Shows or hides the button per `config.floatingButton` and applies behaviour settings. Idempotent.
    func sync(_ model: AppModel) {
        self.model = model
        installHotKey()
        guard model.config.floatingButton else { hide(); return }
        let p = panel ?? makePanel(model)
        p.collectionBehavior = model.config.floatingAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        quick?.collectionBehavior = p.collectionBehavior
        if !p.isVisible {
            p.setFrameOrigin(restoredOrigin(model))
            p.orderFrontRegardless()
        }
        scheduleFade()
    }

    /// Turns the floating button on or off (what the global hotkey does).
    func toggle(_ model: AppModel) {
        model.config.floatingButton.toggle()
        model.save()
        sync(model)
    }

    fileprivate func hotKeyFired() {
        guard let model else { return }
        toggle(model)
    }

    // MARK: panel

    private func makePanel(_ model: AppModel) -> ButtonPanel {
        let s = Self.side
        let p = ButtonPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let container = ButtonContainer(frame: NSRect(x: 0, y: 0, width: s, height: s))
        let host = NSHostingView(rootView: FloatingButtonView().environment(model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.onClick = { [weak self] in self?.toggleQuick() }
        container.onDragStart = { [weak self] in self?.dragBegan() }
        container.onDragEnd = { [weak self] in self?.settle() }
        container.onHover = { [weak self] in self?.hover($0) }
        p.contentView = container
        panel = p
        return p
    }

    private func hide() {
        closeQuick()
        hideTip()
        fadeTimer?.invalidate(); fadeTimer = nil
        panel?.orderOut(nil)
    }

    // MARK: position

    private func screen(containing r: NSRect) -> NSScreen? {
        let c = NSPoint(x: r.midX, y: r.midY)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(c) }) { return s }
        return NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(r), ib = b.frame.intersection(r)
            return ia.width * ia.height < ib.width * ib.height
        } ?? NSScreen.main
    }

    private func restoredOrigin(_ model: AppModel) -> NSPoint {
        let s = Self.side
        if let x = model.config.floatingX, let y = model.config.floatingY {
            let r = NSRect(x: x, y: y, width: s, height: s)
            let c = NSPoint(x: r.midX, y: r.midY)
            if let scr = NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(c) }) {
                let vf = scr.visibleFrame
                return NSPoint(x: min(max(x, vf.minX), vf.maxX - s), y: min(max(y, vf.minY), vf.maxY - s))
            }
        }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: vf.maxX - s - Self.edgeMargin, y: vf.midY - s / 2)
    }

    private func dragBegan() {
        dragging = true
        closeQuick()
        hideTip()
        scheduleFade()
    }

    /// Releases the button: snap to the nearest left/right edge with a spring, then remember where it is.
    private func settle() {
        dragging = false
        guard let p = panel, let model else { return }
        var f = p.frame
        if let vf = screen(containing: f)?.visibleFrame {
            if model.config.floatingSnap {
                f.origin.x = f.midX < vf.midX ? vf.minX + Self.edgeMargin : vf.maxX - f.width - Self.edgeMargin
            } else {
                f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
            }
            f.origin.y = min(max(f.origin.y, vf.minY + Self.edgeMargin), vf.maxY - f.height - Self.edgeMargin)
        }
        model.config.floatingX = Double(f.origin.x)
        model.config.floatingY = Double(f.origin.y)
        model.save()
        if f != p.frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.38
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)   // overshoot, then settle
                p.animator().setFrame(f, display: true)
            }
        }
        scheduleFade()
    }

    // MARK: fade and hover

    private func setAlpha(_ a: CGFloat) {
        guard let p = panel, p.alphaValue != a else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = a
        }
    }

    private func scheduleFade() {
        fadeTimer?.invalidate(); fadeTimer = nil
        setAlpha(1)
        guard let model, model.config.floatingFade, !hovering, !dragging, quick == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.model, m.config.floatingFade, !self.hovering, !self.dragging, self.quick == nil else { return }
                self.setAlpha(0.5)
            }
        }
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            fadeTimer?.invalidate(); fadeTimer = nil
            setAlpha(1)
            tipTimer?.invalidate()
            tipTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showTip() }
            }
        } else {
            hideTip()
            scheduleFade()
        }
    }

    // MARK: tooltip

    private func showTip() {
        guard let model, let bp = panel, quick == nil, !dragging, hovering else { return }
        hideTip()
        let host = NSHostingView(rootView: FloatingTooltipView().environment(model))
        let size = host.fittingSize
        let t = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        t.isFloatingPanel = true
        t.level = .floating
        t.isOpaque = false
        t.backgroundColor = .clear
        t.hasShadow = false
        t.ignoresMouseEvents = true
        t.hidesOnDeactivate = false
        t.isReleasedWhenClosed = false
        t.collectionBehavior = bp.collectionBehavior
        t.contentView = host
        let bf = bp.frame
        let vf = screen(containing: bf)?.visibleFrame ?? .zero
        let onLeft = bf.midX < vf.midX
        let x = onLeft ? bf.maxX - 6 : bf.minX + 6 - size.width
        t.setFrame(NSRect(x: x, y: bf.midY - size.height / 2, width: size.width, height: size.height), display: true)
        t.orderFrontRegardless()
        tip = t
    }

    private func hideTip() {
        tipTimer?.invalidate(); tipTimer = nil
        tip?.orderOut(nil)
        tip = nil
    }

    // MARK: quick panel

    private func toggleQuick() {
        if quick != nil { closeQuick() } else { openQuick() }
    }

    private func openQuick() {
        guard let model, let bp = panel else { return }
        hideTip()
        fadeTimer?.invalidate(); fadeTimer = nil
        setAlpha(1)
        let w: CGFloat = 300
        let bf = bp.frame
        let vf = screen(containing: bf)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let measure = NSHostingView(rootView: QuickPanelView().environment(model))
        let h = min(ceil(measure.fittingSize.height), vf.height - 20)

        let q = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        q.isFloatingPanel = true
        q.level = .floating
        q.isOpaque = false
        q.backgroundColor = .clear
        q.hasShadow = true
        q.hidesOnDeactivate = false
        q.isReleasedWhenClosed = false
        q.collectionBehavior = bp.collectionBehavior
        q.onEscape = { [weak self] in self?.closeQuick() }

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 20
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.separatorColor.cgColor
        let host = NSHostingView(rootView: QuickPanelView(
            maxHeight: h,
            onOpenFull: { [weak self] in self?.closeQuick(); PopoutController.shared.show(model) },
            onHide: { [weak self] in
                model.config.floatingButton = false
                model.save()
                self?.sync(model)
            },
            onClose: { [weak self] in self?.closeQuick() }
        ).environment(model))
        host.frame = fx.bounds
        host.autoresizingMask = [.width, .height]
        fx.addSubview(host)
        q.contentView = fx

        // Beside the button; flips to the other side near a screen edge.
        let onLeft = bf.midX < vf.midX
        var x = onLeft ? bf.maxX - 6 + 8 : bf.minX + 6 - 8 - w
        x = min(max(x, vf.minX + 8), vf.maxX - w - 8)
        let top = min(bf.maxY + 18, vf.maxY - 10)
        let y = max(vf.minY + 10, top - h)
        q.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        q.makeKeyAndOrderFront(nil)
        quick = q

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeQuick() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            var swallow = false
            MainActor.assumeIsolated {
                guard let self else { return }
                if e.type == .keyDown {
                    if e.keyCode == 53 { self.closeQuick(); swallow = true }
                } else if let win = e.window, win !== self.quick, win !== self.panel {
                    self.closeQuick()   // a click in another window of this app
                }
            }
            return swallow ? nil : e
        }
    }

    private func closeQuick() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        guard let q = quick else { return }
        quick = nil
        q.orderOut(nil)
        scheduleFade()
    }

    // MARK: global hotkey (Option-Command-A)

    /// Carbon hot keys need no Accessibility permission, unlike NSEvent global key monitors.
    private func installHotKey() {
        guard !hotKeyHandlerInstalled else { return }
        hotKeyHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), anchorHotKeyHandler, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x414E4348), id: 1)   // 'ANCH'
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
