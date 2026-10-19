import SwiftUI
import AppKit

// MARK: layout

/// Berth sizing: roomy berths while they fit, compact berths next, then a scrolling quay.
private struct HarborLayout {
    enum Mode { case full, compact, scroll }
    let mode: Mode
    let n: Int
    let W: CGFloat
    let sp: CGFloat          // berth pitch
    let w: CGFloat           // berth width
    let ghost: Bool          // dashed "Add" berth after the last account
    let pad: CGFloat
    let contentW: CGFloat

    var maxPan: CGFloat { max(0, contentW - W) }
    func x(_ i: Int) -> CGFloat { pad + sp * (CGFloat(i) + 0.5) }

    init(n: Int, W: CGFloat) {
        self.n = n
        self.W = W
        let fullMax = max(1, Int(W / 86))
        let compactMax = Int(W / 54)
        if n <= fullMax {
            let g = n <= fullMax - 2
            let slots = n + (g ? 1 : 0)
            let pitch = W / CGFloat(max(slots, 1))
            mode = .full; sp = pitch; w = min(100, pitch - 12); ghost = g; pad = 0; contentW = W
        } else if n <= compactMax {
            let pitch = W / CGFloat(n)
            mode = .compact; sp = pitch; w = pitch - 6; ghost = false; pad = 0; contentW = W
        } else {
            mode = .scroll; sp = 82; w = 72; ghost = true; pad = 12; contentW = 24 + 82 * CGFloat(n + 1)
        }
    }
}

// MARK: animatable shapes

/// The chain from the hull to the anchor eye; sags less the more it is stretched.
private struct HarborChain: Shape {
    var hx: CGFloat
    var tip: CGPoint
    var taut: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(tip.x, tip.y) }
        set { tip = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func path(in r: CGRect) -> Path {
        let hy: CGFloat = 10
        let sag: CGFloat = max(8, 46 - abs(tip.x - hx) * 0.12 - (taut ? 20 : 0))
        var p = Path()
        p.move(to: CGPoint(x: hx, y: hy))
        p.addQuadCurve(to: tip, control: CGPoint(x: (hx + tip.x) / 2, y: (hy + tip.y) / 2 + sag))
        return p
    }
}

/// A flat ellipse that widens as `t` runs 0...1 (the splash ring when the anchor lands).
private struct HarborRipple: Shape {
    var cx: CGFloat
    var cy: CGFloat
    var base: CGFloat
    var grow: CGFloat
    var delay: CGFloat
    var t: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(t, cx) }
        set { t = newValue.first; cx = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let k = max(0, (t - delay) / (1 - delay))
        let rx = base + grow * k
        return Path(ellipseIn: CGRect(x: cx - rx, y: cy - rx * 0.26, width: rx * 2, height: rx * 0.52))
    }
}

// MARK: trackpad scrolling

/// Pass-through view that reports horizontal scroll events that land over it (SwiftUI has no hook for them).
private struct HarborScrollCatcher: NSViewRepresentable {
    /// Receives the pan delta; returns true when the event was used.
    var onScroll: (CGFloat) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                let raw = abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
                let dx = -raw * (e.hasPreciseScrollingDeltas ? 1 : 8)
                return (self.onScroll?(dx) ?? false) ? nil : e
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

// MARK: view

/// "Drop the anchor": a harbor scene with one berth per account. Drag the anchor onto a berth (or click one,
/// or use the arrow keys) to make that account the default.
@MainActor struct HarborView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool

    var width: CGFloat
    var onAdd: (() -> Void)?     // makes the dashed "Add" ghost berth tappable; nil leaves it decorative

    @State private var pos: CGPoint?              // anchor eye centre in content coordinates; nil = resting at the default
    @State private var dragging = false
    @State private var grab = CGSize.zero
    @State private var dragVX: CGFloat = 0        // anchor x in viewport coordinates while dragging
    @State private var hotIdx: Int?
    @State private var panOverride: CGFloat?
    @State private var rippleX: CGFloat = 0
    @State private var rippleT: CGFloat = 1
    @State private var motion: Task<Void, Never>?
    @State private var edge: Task<Void, Never>?
    @State private var edgeDir = 0
    @State private var selfCommit: String?
    @State private var swell = false              // water moves briefly after the harbor appears

    private static let height: CGFloat = 220
    private static let dy: CGFloat = 132           // anchor rest height
    private static let berthTop: CGFloat = 144
    private static let berthH: CGFloat = 64
    private static let waterY: CGFloat = 66

    init(width: CGFloat = 316, onAdd: (() -> Void)? = nil) {
        self.width = width
        self.onAdd = onAdd
    }

    // MARK: derived state

    private var berths: [Account] { model.accounts.filter { !$0.pending } }
    private var activeIdx: Int { berths.firstIndex { $0.id == model.config.defaultID } ?? 0 }
    private var layout: HarborLayout { HarborLayout(n: berths.count, W: width) }

    private func clampPan(_ p: CGFloat, _ L: HarborLayout) -> CGFloat { max(0, min(L.maxPan, p)) }
    private func curPan(_ L: HarborLayout) -> CGFloat {
        L.mode == .scroll ? clampPan(panOverride ?? (L.x(activeIdx) - L.W / 2), L) : 0
    }
    private func rest(_ L: HarborLayout) -> CGPoint { CGPoint(x: L.x(activeIdx), y: Self.dy) }

    // MARK: body

    var body: some View {
        let L = layout
        let pan = curPan(L)
        let pt = pos ?? rest(L)
        let vx = pt.x - pan
        let list = berths

        ZStack(alignment: .topLeading) {
            Clay.sky
            // Water moves only while the anchor does, or just after appearing: a pinned pop-out would
            // otherwise redraw at 30 fps all day.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || (pos == nil && !swell))) { tl in
                let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
                Self.sea(width: width, t: t)
            }
            .allowsHitTesting(false)

            HarborRipple(cx: rippleX - pan, cy: Self.waterY, base: 6, grow: 42, delay: 0, t: rippleT)
                .stroke(Clay.accent, lineWidth: 1.5).opacity(Double(1 - rippleT)).allowsHitTesting(false)
            HarborRipple(cx: rippleX - pan, cy: Self.waterY, base: 4, grow: 30, delay: 0.25, t: rippleT)
                .stroke(Clay.accent, lineWidth: 1).opacity(Double(1 - rippleT)).allowsHitTesting(false)

            ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                berth(i, a, L, pan)
                    .offset(x: L.x(i) - pan - L.w / 2, y: Self.berthTop)
            }
            if L.ghost {
                ghostBerth(L)
                    .offset(x: L.x(L.n) - pan - L.w / 2, y: Self.berthTop)
            }

            Group {   // grouped: ViewBuilder takes at most 10 children
                HarborChain(hx: width / 2, tip: CGPoint(x: vx, y: pt.y - 16), taut: dragging)
                    .stroke(Color.black.opacity(0.22), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .allowsHitTesting(false)
                HarborChain(hx: width / 2, tip: CGPoint(x: vx, y: pt.y - 16), taut: dragging)
                    .stroke(Clay.chain, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 3]))
                    .allowsHitTesting(false)
            }
            hull

            if L.mode == .scroll { quayChrome(L, pan) }

            if !list.isEmpty { anchorView(L, vx: vx, ay: pt.y) }
        }
        .frame(width: width, height: Self.height)
        .coordinateSpace(name: "harbor")
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(focused ? Clay.accent : (contrast == .increased ? Color.primary.opacity(0.4) : Clay.hairline),
                          lineWidth: focused ? 2 : 1)
            .allowsHitTesting(false))
        .background(HarborScrollCatcher { wheel($0) })
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onAppear { if layout.mode == .scroll { panOverride = curPan(layout) } }
        .task {
            swell = true
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            swell = false
        }
        .onDisappear { motion?.cancel(); edge?.cancel(); pos = nil; dragging = false; hotIdx = nil; edgeDir = 0 }
        .onChange(of: model.config.defaultID) { old, new in defaultChanged(from: old, to: new) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Default account")
        .accessibilityValue(list.isEmpty ? "None" : "\(list[min(activeIdx, list.count - 1)].name), \(activeIdx + 1) of \(list.count)")
        .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
    }

    // MARK: scene pieces

    private static func wave(base: CGFloat, amp: CGFloat, dx: CGFloat, width: CGFloat, bottom: CGFloat?) -> Path {
        var p = Path()
        var x = dx
        var k = 0
        p.move(to: CGPoint(x: x, y: base))
        while x < width + 87 {
            p.addQuadCurve(to: CGPoint(x: x + 43.5, y: base),
                           control: CGPoint(x: x + 21.75, y: base + (k % 2 == 0 ? -amp : amp)))
            x += 43.5
            k += 1
        }
        if let b = bottom {
            p.addLine(to: CGPoint(x: x, y: b))
            p.addLine(to: CGPoint(x: dx, y: b))
            p.closeSubpath()
        }
        return p
    }

    /// Shapes, not Canvas: the first Canvas on screen costs about 100 MB of graphics memory.
    private static func sea(width: CGFloat, t: Double) -> some View {
        let d1 = -CGFloat((t / 7).truncatingRemainder(dividingBy: 1)) * 87
        let d2 = -CGFloat((t / 11).truncatingRemainder(dividingBy: 1)) * 87
        var bed = Path()
        bed.move(to: CGPoint(x: 0, y: 190))
        bed.addQuadCurve(to: CGPoint(x: width / 2, y: 186), control: CGPoint(x: width / 4, y: 178))
        bed.addQuadCurve(to: CGPoint(x: width, y: 182), control: CGPoint(x: width * 0.75, y: 194))
        bed.addLine(to: CGPoint(x: width, y: height))
        bed.addLine(to: CGPoint(x: 0, y: height))
        bed.closeSubpath()
        return ZStack(alignment: .topLeading) {
            wave(base: waterY, amp: 7, dx: d1, width: width, bottom: height).fill(Clay.sea)
            wave(base: waterY + 8, amp: 5, dx: d2, width: width, bottom: nil).stroke(Clay.foam, lineWidth: 1.2)
            bed.fill(Clay.seabed)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var hull: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Clay.surface2)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Clay.hairline, lineWidth: 1))
                .frame(width: 84, height: 24)
                .offset(x: width / 2 - 42, y: -12)
            Circle().fill(Clay.accent).frame(width: 9, height: 9)
                .offset(x: width / 2 - 4.5, y: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ghostBerth(_ L: HarborLayout) -> some View {
        let art = VStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
            Text("Add").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .frame(width: L.w, height: Self.berthH)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        return Group {
            if let onAdd {
                Button(action: onAdd) { art }.buttonStyle(.plain)
                    .help("Add account").accessibilityLabel("Add account")
            } else {
                art.help("Add accounts in Settings").accessibilityHidden(true)
            }
        }
    }

    // MARK: berths

    private func shortName(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }

    private func status(pct: Double?, fresh: Bool, on: Bool, roomy: Bool, countdown: String?) -> (text: String, color: Color) {
        if fresh { return (roomy ? (on ? "Anchored · full 5h" : "Full 5h window") : "Full", Clay.fresh) }
        guard let p = pct else { return ("—", Color.secondary) }
        let n = Int(p.rounded())
        if on { return (roomy ? "Anchored · \(n)%" : "\(n)%", Clay.accentText) }
        if roomy, let c = countdown { return ("\(n)% · ↻ \(c)", Clay.color(p)) }
        return ((roomy ? "5h " : "") + "\(n)%", Clay.color(p))
    }

    private func berth(_ i: Int, _ a: Account, _ L: HarborLayout, _ pan: CGFloat) -> some View {
        let roomy = L.mode == .full
        let on = i == activeIdx && !dragging
        let hot = i == hotIdx
        let pct = model.limits[a.id]?.fiveHour?.percent
        let fresh = model.isFresh(a.id)
        let countdown: String? = (pct ?? 0) >= 75 ? model.resetCountdown(a.id) : nil
        let st = status(pct: pct, fresh: fresh, on: on, roomy: roomy, countdown: countdown)
        let lit = hot || on
        var label = "Anchor at \(a.name), "
        if fresh { label += "fresh 5-hour window" }
        else if let p = pct { label += "5-hour limit \(Int(p.rounded())) percent used" + (countdown.map { ", resets in \($0)" } ?? "") }
        else { label += "5-hour limit unknown" }
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        return Button { pick(i) } label: {
            VStack(spacing: 3) {
                FlagView(flag: a.flag, size: roomy ? 13 : 11)
                Text(roomy ? a.name : shortName(a.name))
                    .font(.system(size: roomy ? 12.5 : 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                Text(st.text)
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(st.color)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 4)
            .frame(width: L.w, height: Self.berthH)
            .background {
                ZStack {
                    if lit {
                        RoundedRectangle(cornerRadius: 13 + (hot ? 4 : 3), style: .continuous)
                            .fill(Clay.accent.opacity(0.12)).padding(hot ? -4 : -3)
                    }
                    shape.fill(Clay.surface)
                    if lit { shape.fill(Clay.accent.opacity(0.12)) }
                }
            }
            .overlay(shape.strokeBorder(lit ? Clay.accent : (contrast == .increased ? Color.primary.opacity(0.4) : Clay.hairline),
                                        lineWidth: hot ? 1.5 : 1))
            .shadow(color: Clay.accent.opacity(hot ? 0.3 : 0), radius: 11)
            .overlay(alignment: .topTrailing) { if fresh { freshBadge(roomy) } }
            .contentShape(shape)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hot)
        }
        .buttonStyle(.plain)
        .help(a.name)
        .accessibilityLabel(label)
        .accessibilityHint(on ? "Current default account" : "Makes this the default account")
        .accessibilityAddTraits(i == activeIdx ? .isSelected : [])
    }

    private func freshBadge(_ roomy: Bool) -> some View {
        Group {
            if roomy {
                Text("FRESH").font(.system(size: 9, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(Clay.freshInk).padding(.horizontal, 6).frame(height: 15)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }
        }
        .background(Clay.fresh, in: Capsule())
        .padding(2)
        .background(Clay.sea, in: Capsule())
        .offset(x: roomy ? 7 : 3, y: -9)
        .accessibilityHidden(true)
    }

    // MARK: quay chrome (scrolling mode)

    private func quayChrome(_ L: HarborLayout, _ pan: CGFloat) -> some View {
        let canL = pan > 2, canR = pan < L.maxPan - 2
        let pages = max(1, Int(ceil(L.contentW / L.W)))
        let curPage = Int((pan / max(1, L.maxPan) * CGFloat(pages - 1)).rounded())
        let pageW = 82 * CGFloat(max(2, Int(L.W / 82) - 1))
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Clay.sea, Clay.sea.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 34, height: 90).offset(x: 0, y: 130).opacity(canL ? 1 : 0).allowsHitTesting(false)
            LinearGradient(colors: [Clay.sea, Clay.sea.opacity(0)], startPoint: .trailing, endPoint: .leading)
                .frame(width: 34, height: 90).offset(x: L.W - 34, y: 130).opacity(canR ? 1 : 0).allowsHitTesting(false)
            if canL { arrow("chevron.left", "Show earlier accounts") { panTo(pan - pageW, L) }.offset(x: 6, y: 92) }
            if canR { arrow("chevron.right", "Show more accounts") { panTo(pan + pageW, L) }.offset(x: L.W - 32, y: 92) }
            HStack(spacing: 4) {
                ForEach(0..<pages, id: \.self) { p in
                    Capsule().fill(p == curPage ? Clay.accent : Color.primary.opacity(0.24))
                        .frame(width: p == curPage ? 12 : 4, height: 3)
                }
            }
            .padding(.bottom, 4)
            .frame(width: L.W, height: Self.height, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func arrow(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(Clay.surface, in: Circle())
                .overlay(Circle().strokeBorder(Clay.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: anchor

    private func anchorView(_ L: HarborLayout, vx: CGFloat, ay: CGFloat) -> some View {
        let tilt = atan2(Double(vx - width / 2), Double(max(20, ay - 10))) * -40 / Double.pi
        let pivot = UnitPoint(x: 0.5, y: 0.2)
        return ZStack {
            AnchorGlyph().stroke(Clay.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 26)
        }
        .frame(width: 40, height: 40)
        .contentShape(Circle())
        .scaleEffect(dragging ? 1.12 : 1, anchor: pivot)
        .rotationEffect(.degrees(tilt), anchor: pivot)
        .shadow(color: .black.opacity(0.28), radius: 6, y: 4)
        .shadow(color: Clay.accent.opacity(dragging ? 0.8 : 0), radius: 8)
        .offset(x: vx - 20, y: ay - 20)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("harbor"))
                .onChanged { dragChanged($0) }
                .onEnded { _ in dragEnded() },
            including: L.n >= 2 ? .all : .none)
        .accessibilityHidden(true)
    }

    // MARK: interaction

    private func hotAt(_ p: CGPoint, _ L: HarborLayout) -> Int? {
        guard p.y >= 76 else { return nil }
        var hot: Int?
        var best = L.sp * 0.55 + 6
        for i in 0..<L.n {
            let d = abs(p.x - L.x(i))
            if d < best { best = d; hot = i }
        }
        return hot
    }

    private func setHot(_ h: Int?) {
        guard h != hotIdx else { return }
        hotIdx = h
        if h != nil { tick(.alignment) }
    }

    private func tick(_ p: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
    }

    private func dragChanged(_ v: DragGesture.Value) {
        let L = layout
        if !dragging {
            motion?.cancel(); motion = nil
            let pan = curPan(L)
            let cur = pos ?? rest(L)
            grab = CGSize(width: (cur.x - pan) - v.startLocation.x, height: cur.y - v.startLocation.y)
            if L.mode == .scroll { panOverride = pan }
            pos = cur
            dragging = true
        }
        let pan = curPan(L)
        dragVX = min(width - 18, max(18, v.location.x + grab.width))
        let y = min(Self.dy + 34, max(34, v.location.y + grab.height))
        let p = CGPoint(x: dragVX + pan, y: y)
        pos = p
        setHot(hotAt(p, L))
        if L.mode == .scroll { setEdge(dragVX < 44 ? -1 : dragVX > width - 44 ? 1 : 0) }
    }

    private func dragEnded() {
        guard dragging else { return }
        setEdge(0)
        let hot = hotIdx
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { dragging = false }
        hotIdx = nil
        if let hot { dock(hot) } else { glideHome() }
    }

    /// Auto-scroll the quay while the anchor is held near an edge.
    private func setEdge(_ dir: Int) {
        guard dir != edgeDir else { return }
        edgeDir = dir
        edge?.cancel(); edge = nil
        guard dir != 0 else { return }
        edge = Task { @MainActor in
            while !Task.isCancelled && dragging && edgeDir != 0 {
                let L = layout
                let p = clampPan(curPan(L) + CGFloat(edgeDir) * 5, L)
                panOverride = p
                let np = CGPoint(x: dragVX + p, y: pos?.y ?? Self.dy)
                pos = np
                setHot(hotAt(np, L))
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// Released over a berth: settle with a spring, ripple, haptic, then make it the default.
    private func dock(_ i: Int) {
        let L = layout
        guard berths.indices.contains(i) else { glideHome(); return }
        let bx = L.x(i)
        if L.mode == .scroll {
            let vx = bx - curPan(L)
            if vx < 60 || vx > L.W - 60 { panTo(bx - L.W / 2, L) }
        }
        splash(bx)
        tick(.levelChange)
        let target = CGPoint(x: bx, y: Self.dy)
        if reduceMotion { pos = target } else { withAnimation(.spring(response: 0.42, dampingFraction: 0.5)) { pos = target } }
        commit(i)
        motion?.cancel()
        motion = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            pos = nil
        }
    }

    /// Released elsewhere: back to the current default.
    private func glideHome() {
        let home = rest(layout)
        motion?.cancel()
        if reduceMotion { pos = nil; return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { pos = home }
        motion = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            pos = nil
        }
    }

    /// Lift, cross, drop. `commitIt` is false when the default already changed elsewhere.
    private func sail(from start: CGPoint, to i: Int, commitIt: Bool) {
        let L = layout
        guard berths.indices.contains(i) else { return }
        motion?.cancel()
        let bx = L.x(i)
        if L.mode == .scroll { panTo(bx - L.W / 2, L) }
        if reduceMotion {
            pos = CGPoint(x: bx, y: Self.dy)
            tick(.levelChange)
            if commitIt { commit(i) }
            pos = nil
            return
        }
        pos = start
        motion = Task { @MainActor in
            let lift = Self.dy - 90
            withAnimation(.easeOut(duration: 0.2)) { pos = CGPoint(x: start.x, y: lift) }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { pos = CGPoint(x: bx, y: lift) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { pos = CGPoint(x: bx, y: Self.dy) }
            splash(bx)
            tick(.levelChange)
            if commitIt { commit(i) }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            pos = nil
        }
    }

    private func splash(_ x: CGFloat) {
        guard !reduceMotion else { return }
        rippleX = x
        rippleT = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            withAnimation(.easeOut(duration: 0.9)) { rippleT = 1 }
        }
    }

    private func commit(_ i: Int) {
        let list = berths
        guard list.indices.contains(i), list[i].id != model.config.defaultID else { return }
        selfCommit = list[i].id
        model.setDefault(list[i].id)
    }

    private func pick(_ i: Int) {
        guard i != activeIdx, !dragging else { return }
        sail(from: pos ?? rest(layout), to: i, commitIt: true)
    }

    private func step(_ d: Int) {
        let j = activeIdx + d
        guard berths.indices.contains(j), !dragging else { return }
        sail(from: pos ?? rest(layout), to: j, commitIt: true)
    }

    /// The default changed from outside (another view): sail over instead of jumping.
    private func defaultChanged(from old: String, to new: String) {
        if selfCommit == new { selfCommit = nil; return }
        guard !dragging, pos == nil else { return }
        let list = berths
        guard let from = list.firstIndex(where: { $0.id == old }),
              let to = list.firstIndex(where: { $0.id == new }) else { return }
        let L = layout
        sail(from: CGPoint(x: L.x(from), y: Self.dy), to: to, commitIt: false)
    }

    private func panTo(_ target: CGFloat, _ L: HarborLayout) {
        guard L.mode == .scroll else { return }
        let t = clampPan(target, L)
        if reduceMotion { panOverride = t } else { withAnimation(.easeInOut(duration: 0.38)) { panOverride = t } }
    }

    private func wheel(_ dx: CGFloat) -> Bool {
        let L = layout
        guard L.mode == .scroll, !dragging else { return false }
        panOverride = clampPan(curPan(L) + dx, L)
        return true
    }
}
