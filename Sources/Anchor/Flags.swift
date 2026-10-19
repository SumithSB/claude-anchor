import SwiftUI
import AppKit

// Palette tokens (see plan: Design direction).
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            NSColor(hex: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
    static let enamel = dynamic(light: 0xF5F5F0, dark: 0x18202B)
    static let brass = Color(nsColor: NSColor(hex: 0xA8834A))
    static let signalRed = Color(nsColor: NSColor(hex: 0xB3122E))
    static let flagBlue = Color(nsColor: NSColor(hex: 0x1F3F8F))
    static let flagYellow = Color(nsColor: NSColor(hex: 0xF2C230))
}

/// International Code of Signals flag, 3:2 (A and B are swallowtails).
@MainActor struct FlagView: View {
    let flag: SignalFlag
    var size: CGFloat = 14

    // Shapes, not Canvas: the first Canvas on screen costs about 100 MB of graphics memory.
    var body: some View {
        GeometryReader { g in
            let art = FlagArt.art(flag, CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(art.fills.indices, id: \.self) { i in art.fills[i].path.fill(art.fills[i].color) }
                ForEach(art.strokes.indices, id: \.self) { i in
                    art.strokes[i].path.stroke(art.strokes[i].color, lineWidth: art.strokes[i].width)
                }
            }
            .overlay(art.outline.stroke(Color.black.opacity(0.3), lineWidth: 0.5))
            .clipShape(art.outline)   // inner half of the outline only, as the Canvas clip showed it
        }
        .frame(width: size * 1.5, height: size)
        .accessibilityLabel("Flag \(flag.letter)")
    }
}

enum FlagArt {
    static let W = Color.white, K = Color.black, R = Color.signalRed, B = Color.flagBlue, Y = Color.flagYellow

    struct Art {
        var outline = Path()
        var fills: [(path: Path, color: Color)] = []
        var strokes: [(path: Path, color: Color, width: CGFloat)] = []
    }

    /// The flag as paths in `r`; FlagView clips them to `outline` and strokes the outline on top.
    static func art(_ f: SignalFlag, _ r: CGRect) -> Art {
        var g = Art()
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ c: Color) {
            let a = P(x0, y0), b = P(x1, y1)   // +0.3 overlap hides antialiasing seams between neighbours
            g.fills.append((Path(CGRect(x: a.x, y: a.y, width: b.x - a.x + 0.3, height: b.y - a.y + 0.3)), c))
        }
        func poly(_ pts: [(CGFloat, CGFloat)], _ c: Color) {
            var p = Path(); p.addLines(pts.map { P($0.0, $0.1) }); p.closeSubpath(); g.fills.append((p, c))
        }
        func hs(_ cols: [Color]) { for (i, c) in cols.enumerated() { box(0, CGFloat(i) / CGFloat(cols.count), 1, CGFloat(i + 1) / CGFloat(cols.count), c) } }
        func vs(_ cols: [Color]) { for (i, c) in cols.enumerated() { box(CGFloat(i) / CGFloat(cols.count), 0, CGFloat(i + 1) / CGFloat(cols.count), 1, c) } }
        func quarters(_ a: Color, _ b: Color, _ c: Color, _ d: Color) {
            box(0, 0, 0.5, 0.5, a); box(0.5, 0, 1, 0.5, b); box(0, 0.5, 0.5, 1, c); box(0.5, 0.5, 1, 1, d)
        }
        func saltire(_ c: Color) {
            var p = Path(); p.move(to: P(0, 0)); p.addLine(to: P(1, 1)); p.move(to: P(1, 0)); p.addLine(to: P(0, 1))
            g.strokes.append((p, c, r.height * 0.24))
        }
        func cross(_ c: Color) { box(0.43, 0, 0.57, 1, c); box(0, 0.4, 1, 0.6, c) }

        if f == .a || f == .b { g.outline.addLines([P(0, 0), P(1, 0), P(0.72, 0.5), P(1, 1), P(0, 1)]); g.outline.closeSubpath() }
        else { g.outline.addRect(r) }

        switch f {
        case .a: box(0, 0, 0.5, 1, W); box(0.5, 0, 1, 1, B)
        case .b: box(0, 0, 1, 1, R)
        case .c: hs([B, W, R, W, B])
        case .d: hs([Y, B, Y])
        case .e: hs([B, R])
        case .f: box(0, 0, 1, 1, W); poly([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)], R)
        case .g: vs([Y, B, Y, B, Y, B])
        case .h: vs([W, R])
        case .i:
            box(0, 0, 1, 1, Y)
            let c = P(0.5, 0.5), rr = r.height * 0.26
            g.fills.append((Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), K))
        case .j: hs([B, W, B])
        case .k: vs([Y, B])
        case .l: quarters(Y, K, K, Y)
        case .m: box(0, 0, 1, 1, B); saltire(W)
        case .n:
            box(0, 0, 1, 1, W)
            for row in 0..<4 { for col in 0..<4 where (row + col) % 2 == 0 {
                box(CGFloat(col) / 4, CGFloat(row) / 4, CGFloat(col + 1) / 4, CGFloat(row + 1) / 4, B) } }
        case .o: box(0, 0, 1, 1, R); poly([(0, 0), (0, 1), (1, 1)], Y)
        case .p: box(0, 0, 1, 1, B); box(0.25, 0.25, 0.75, 0.75, W)
        case .q: box(0, 0, 1, 1, Y)
        case .r: box(0, 0, 1, 1, R); cross(Y)
        case .s: box(0, 0, 1, 1, W); box(0.25, 0.25, 0.75, 0.75, B)
        case .t: vs([R, W, B])
        case .u: quarters(R, W, W, R)
        case .v: box(0, 0, 1, 1, W); saltire(R)
        case .w: box(0, 0, 1, 1, B); box(0.14, 0.14, 0.86, 0.86, W); box(0.3, 0.3, 0.7, 0.7, R)
        case .x: box(0, 0, 1, 1, W); cross(B)
        case .y:
            box(0, 0, 1, 1, Y)
            for k in stride(from: 1, to: 8, by: 2) {
                let a = CGFloat(k) * 0.25, b = a + 0.25
                poly([(a, 0), (b, 0), (b - 1, 1), (a - 1, 1)], R)
            }
        case .z:
            poly([(0, 0), (1, 0), (0.5, 0.5)], Y); poly([(1, 0), (1, 1), (0.5, 0.5)], B)
            poly([(1, 1), (0, 1), (0.5, 0.5)], K); poly([(0, 1), (0, 0), (0.5, 0.5)], R)
        }
        return g
    }
}

// MARK: flag picker and accounts pane

@MainActor private struct FlagCell: View {
    let flag: SignalFlag
    let selected: Bool
    let dimmed: Bool
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: pick) {
            FlagView(flag: flag, size: 20).padding(4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? Color.brass : .clear, lineWidth: 1.5))
                .opacity(dimmed ? 0.35 : 1)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityLabel("Flag \(flag.letter)").accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor struct FlagGrid: View {
    @Binding var flag: SignalFlag
    var used: Set<SignalFlag> = []
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(46)), count: 6), spacing: 6) {
            ForEach(SignalFlag.allCases) { f in
                FlagCell(flag: f, selected: f == flag, dimmed: used.contains(f) && f != flag) { flag = f }
            }
        }.padding(12)
    }
}

@MainActor struct AccountsPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: String?
    @State private var draft = ""
    @State private var flagFor: String?
    @State private var removing: Account?
    @State private var signOut = false
    @State private var adding = false
    @State private var newName = ""
    @State private var newFlag = SignalFlag.a
    @State private var showNewFlags = false

    private var used: Set<SignalFlag> { Set(model.accounts.map(\.flag)) }

    var body: some View {
        PaneScaffold(title: "Accounts") {
            PaneSection(title: "Signed in", footer: "New sessions start on the default account. Use ⋯ to rename, change the flag or reorder.") {
                ForEach(Array(model.accounts.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { RowDivider() }
                    row(a, index: i)
                }
                if !adding {
                    RowDivider()
                    Button {
                        newName = ""; newFlag = SignalFlag.allCases.first { !used.contains($0) } ?? .a; adding = true
                    } label: {
                        Label("Add account", systemImage: "plus").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Clay.accentText)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if adding { PaneSection(title: "New account") { addForm.padding(.vertical, 10) } }
        }
        .sheet(item: $removing) { RemoveSheet(account: $0) }
        .confirmationDialog("Sign out of Claude Code?", isPresented: $signOut) {
            Button("Sign out", role: .destructive) { model.signOutPrimary() }
        }
    }

    private func row(_ a: Account, index i: Int) -> some View {
        HStack(spacing: 10) {
            FlagView(flag: a.flag, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                if editing == a.id {
                    TextField("Name", text: $draft).textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit { model.rename(a.id, to: draft); editing = nil }
                } else {
                    Text(a.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                        .onTapGesture(count: 2) { draft = a.name; editing = a.id }
                }
                if model.signingIn.contains(a.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Finish signing in in your browser").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Button("Cancel") { model.cancelSignIn(a.id) }.controlSize(.mini)
                    }
                } else if a.pending {
                    HStack(spacing: 6) {
                        Text("Not signed in").font(.subheadline).foregroundStyle(.secondary)
                        Button("Sign in") { model.signIn(a.id) }.controlSize(.mini)
                    }
                } else if let e = a.email { Text(e).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 6)
            if let p = a.plan, !a.pending {
                Text(p.capitalized).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Clay.surface2))
            }
            RowMenu(label: "Options for \(a.name)") {
                Button("Rename") { draft = a.name; editing = a.id }
                Button("Change flag") { flagFor = a.id }
                Button("Sign in again") { model.signIn(a.id) }
                if i > 0 { Button("Move up") { model.moveAccounts(fromOffsets: [i], toOffset: i - 1) } }
                if i < model.accounts.count - 1 { Button("Move down") { model.moveAccounts(fromOffsets: [i], toOffset: i + 2) } }
                Divider()
                if a.isPrimary { Button("Sign out") { signOut = true } }
                else { Button("Remove \(a.name)", role: .destructive) { removing = a } }
            }
        }
        .padding(.vertical, 9)
        .popover(isPresented: Binding(get: { flagFor == a.id }, set: { if !$0 { flagFor = nil } })) {
            FlagGrid(flag: Binding(get: { a.flag }, set: { model.setFlag(a.id, $0); flagFor = nil }), used: used)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Account name", text: $newName).textFieldStyle(.roundedBorder)
                Button { showNewFlags = true } label: { FlagView(flag: newFlag, size: 16) }.buttonStyle(.borderless)
                    .popover(isPresented: $showNewFlags) { FlagGrid(flag: Binding(get: { newFlag }, set: { newFlag = $0; showNewFlags = false }), used: used) }
                    .accessibilityLabel("Flag \(newFlag.letter), change")
            }
            HStack {
                Button("Cancel") { adding = false }
                Spacer()
                Button("Sign in with browser") {
                    model.addAccount(name: newName.trimmingCharacters(in: .whitespaces), flag: newFlag)
                    adding = false
                }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.controlSize(.small)
    }
}

@MainActor struct RemoveSheet: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""

    var body: some View {
        let others = model.accounts.filter { $0.id != account.id }
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove \(account.name)").font(.system(size: 13, weight: .semibold))
            Text("Its config folder moves to the Trash. Usage already logged stays in your history.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Move its folder rules to", selection: $target) {
                ForEach(others) { Text($0.name).tag($0.id) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove \(account.name)", role: .destructive) { model.removeAccount(account.id, reassignTo: target); dismiss() }
                    .disabled(target.isEmpty && !others.isEmpty)
            }
        }
        .padding(16).frame(width: 320)
        .onAppear { target = others.contains { $0.id == model.config.defaultID } ? model.config.defaultID : (others.first?.id ?? "") }
    }
}
