import SwiftUI
import AppKit

/// Engine order telegraph: a half dial, one sector per account, a brass lever that points at the default.
@MainActor struct TelegraphView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool
    @State private var dragPos: Double?      // 0...1 along the arc while dragging
    @State private var lastSector = -1
    var previewPos: Double? = nil            // video renders only: fixes the lever position (the hot label follows)

    private let W: CGFloat = 308, H: CGFloat = 156, R: CGFloat = 145
    private let C = CGPoint(x: 154, y: 148)

    private var accounts: [Account] { model.accounts }
    private var n: Int { max(accounts.count, 1) }
    private var activeIdx: Int { accounts.firstIndex { $0.id == model.config.defaultID } ?? 0 }
    private func center(_ i: Int) -> Double { (Double(i) + 0.5) / Double(n) }
    private var pos: Double { previewPos ?? dragPos ?? center(activeIdx) }
    private var hot: Int { min(n - 1, max(0, Int(pos * Double(n)))) }   // sector under the lever

    // Sectors sweep 15°–165° so end labels clear the baseline rim.
    private static let inset = 1.0 / 12
    private func sweep(_ pos: Double) -> Double { Self.inset + pos * (1 - 2 * Self.inset) }

    private func pt(_ pos: Double, _ r: CGFloat) -> CGPoint {
        let a = Double.pi * (1 - sweep(pos))
        return CGPoint(x: C.x + r * CGFloat(cos(a)), y: C.y - r * CGFloat(sin(a)))
    }

    var body: some View {
        ZStack {
            Canvas { ctx, _ in drawFace(&ctx) }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { i, a in label(i, a) }
            lever
        }
        .frame(width: W, height: H)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(dragged).onEnded(released))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .background { shortcuts }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Account")
        .accessibilityValue("\(accounts.isEmpty ? "None" : accounts[activeIdx].name), \(activeIdx + 1) of \(n)")
        .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
    }

    // MARK: drawing

    private func drawFace(_ ctx: inout GraphicsContext) {
        var face = Path()
        face.addArc(center: C, radius: R, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        face.closeSubpath()
        ctx.fill(face, with: .color(.enamel))
        let ink = Color.primary
        for k in 0...(n * 5) {
            let major = k % 5 == 0
            var t = Path(); t.move(to: pt(Double(k) / Double(n * 5), R - (major ? 15 : 9)))
            t.addLine(to: pt(Double(k) / Double(n * 5), R - 5))
            ctx.stroke(t, with: .color(ink.opacity(contrast == .increased ? (major ? 0.8 : 0.5) : (major ? 0.45 : 0.2))), lineWidth: major ? 1 : 0.75)
        }
        var d = Path(); d.move(to: pt(center(hot), R - 18)); d.addLine(to: pt(center(hot), R - 5))
        ctx.stroke(d, with: .color(.brass), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        ctx.stroke(face, with: .color(.brass), lineWidth: focused || contrast == .increased ? 3.5 : 2)
    }

    private func label(_ i: Int, _ a: Account) -> some View {
        let a0 = Double.pi * (1 - sweep(center(i)))
        // chord between neighbouring label centres, wider toward the sides where labels stack vertically
        let chord = 2 * R * 0.72 * CGFloat(sin(Double.pi * (1 - 2 * Self.inset) / Double(2 * n)))
        let w = min(92, chord - 6 + 34 * CGFloat(abs(cos(a0))))
        return VStack(spacing: 4) {
            FlagView(flag: a.flag, size: 16)
            Text(a.name).font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: w)
        .foregroundStyle(i == hot ? Color.primary : Color.secondary)
        .opacity(a.pending ? 0.4 : 1)
        .position(pt(center(i), R * 0.72))
    }

    private var lever: some View {
        let len: CGFloat = 62
        return ZStack {
            ZStack(alignment: .top) {
                Capsule().fill(Color.brass).frame(width: 5, height: len - 6).offset(y: 6)
                Circle().fill(Color.brass).frame(width: 12, height: 12)
            }
            .frame(width: 12, height: len)
            .rotationEffect(.radians((sweep(pos) - 0.5) * .pi), anchor: .bottom)
            .position(x: C.x, y: C.y - len / 2)
            Circle().fill(Color.brass).frame(width: 15, height: 15)
                .overlay(Circle().fill(Color.enamel).frame(width: 5, height: 5))
                .position(C)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1.5)
        .animation(dragPos == nil && previewPos == nil && !reduceMotion ? .spring(response: 0.35, dampingFraction: 0.7) : nil, value: pos)
        .allowsHitTesting(false)
    }

    private var shortcuts: some View {
        ForEach(0..<6, id: \.self) { i in
            Button("") { select(i) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
        }.accessibilityHidden(true)
    }

    // MARK: interaction

    private func dragged(_ v: DragGesture.Value) {
        let phi = max(-Double.pi / 2, min(Double.pi / 2, atan2(v.location.x - C.x, max(C.y - v.location.y, 0.001))))
        let p = min(1, max(0, (phi / .pi + 0.5 - Self.inset) / (1 - 2 * Self.inset)))
        let s = min(n - 1, Int(p * Double(n)))
        if lastSector >= 0, s != lastSector {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastSector = s
        dragPos = p
    }

    private func released(_ v: DragGesture.Value) {
        let p = dragPos ?? pos
        let target = accounts.indices.filter { !accounts[$0].pending }.min { abs(center($0) - p) < abs(center($1) - p) }
        dragPos = nil; lastSector = -1
        if let target { select(target) }
    }

    private func select(_ i: Int) {
        guard accounts.indices.contains(i), !accounts[i].pending, accounts[i].id != model.config.defaultID else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        model.setDefault(accounts[i].id)
    }

    private func step(_ d: Int) {
        var i = activeIdx + d
        while accounts.indices.contains(i), accounts[i].pending { i += d }
        select(i)
    }
}
