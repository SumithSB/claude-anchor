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
struct FlagView: View {
    let flag: SignalFlag
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, sz in FlagArt.draw(flag, ctx, CGRect(origin: .zero, size: sz)) }
            .frame(width: size * 1.5, height: size)
            .accessibilityLabel("Flag \(flag.letter)")
    }
}

enum FlagArt {
    static let W = Color.white, K = Color.black, R = Color.signalRed, B = Color.flagBlue, Y = Color.flagYellow

    static func draw(_ f: SignalFlag, _ ctx: GraphicsContext, _ r: CGRect) {
        var g = ctx
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ c: Color) {
            let a = P(x0, y0), b = P(x1, y1)   // +0.3 overlap hides antialiasing seams between neighbours
            g.fill(Path(CGRect(x: a.x, y: a.y, width: b.x - a.x + 0.3, height: b.y - a.y + 0.3)), with: .color(c))
        }
        func poly(_ pts: [(CGFloat, CGFloat)], _ c: Color) {
            var p = Path(); p.addLines(pts.map { P($0.0, $0.1) }); p.closeSubpath(); g.fill(p, with: .color(c))
        }
        func hs(_ cols: [Color]) { for (i, c) in cols.enumerated() { box(0, CGFloat(i) / CGFloat(cols.count), 1, CGFloat(i + 1) / CGFloat(cols.count), c) } }
        func vs(_ cols: [Color]) { for (i, c) in cols.enumerated() { box(CGFloat(i) / CGFloat(cols.count), 0, CGFloat(i + 1) / CGFloat(cols.count), 1, c) } }
        func quarters(_ a: Color, _ b: Color, _ c: Color, _ d: Color) {
            box(0, 0, 0.5, 0.5, a); box(0.5, 0, 1, 0.5, b); box(0, 0.5, 0.5, 1, c); box(0.5, 0.5, 1, 1, d)
        }
        func saltire(_ c: Color) {
            var p = Path(); p.move(to: P(0, 0)); p.addLine(to: P(1, 1)); p.move(to: P(1, 0)); p.addLine(to: P(0, 1))
            g.stroke(p, with: .color(c), lineWidth: r.height * 0.24)
        }
        func cross(_ c: Color) { box(0.43, 0, 0.57, 1, c); box(0, 0.4, 1, 0.6, c) }

        var outline = Path()
        if f == .a || f == .b { outline.addLines([P(0, 0), P(1, 0), P(0.72, 0.5), P(1, 1), P(0, 1)]); outline.closeSubpath() }
        else { outline.addRect(r) }
        g.clip(to: outline)

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
            g.fill(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)), with: .color(K))
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
        ctx.stroke(outline, with: .color(.black.opacity(0.3)), lineWidth: 0.5)
    }
}

// MARK: flag picker and accounts pane

struct FlagGrid: View {
    @Binding var flag: SignalFlag
    var used: Set<SignalFlag> = []
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 6), spacing: 8) {
            ForEach(SignalFlag.allCases) { f in
                Button { flag = f } label: {
                    FlagView(flag: f, size: 20).padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(f == flag ? Color.brass : .clear, lineWidth: 1.5))
                        .opacity(used.contains(f) && f != flag ? 0.35 : 1)
                }.buttonStyle(.plain).accessibilityLabel("Flag \(f.letter)")
            }
        }.padding(12)
    }
}

struct AccountsPane: View {
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
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Accounts")
            List {
                ForEach(model.accounts) { row($0) }.onMove { model.moveAccounts(fromOffsets: $0, toOffset: $1) }
            }.listStyle(.plain)
            Divider()
            if adding { addForm } else {
                Button("Add account") {
                    newName = ""; newFlag = SignalFlag.allCases.first { !used.contains($0) } ?? .a; adding = true
                }.padding(12).controlSize(.small)
            }
        }
        .frame(width: 340, height: 440)
        .sheet(item: $removing) { RemoveSheet(account: $0) }
        .confirmationDialog("Sign out of Claude Code?", isPresented: $signOut) {
            Button("Sign out", role: .destructive) { model.signOutPrimary() }
        }
    }

    private func row(_ a: Account) -> some View {
        HStack(spacing: 10) {
            FlagView(flag: a.flag, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                if editing == a.id {
                    TextField("Name", text: $draft).textFieldStyle(.roundedBorder).controlSize(.small)
                        .onSubmit { model.rename(a.id, to: draft); editing = nil }
                } else {
                    Text(a.name).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .onTapGesture(count: 2) { draft = a.name; editing = a.id }
                }
                if model.signingIn.contains(a.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Finish signing in in your browser").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Cancel") { model.cancelSignIn(a.id) }.controlSize(.mini)
                    }
                } else if a.pending {
                    HStack(spacing: 6) {
                        Text("Not signed in").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Sign in") { model.signIn(a.id) }.controlSize(.mini)
                    }
                } else if let e = a.email { Text(e).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Menu {
                Button("Rename") { draft = a.name; editing = a.id }
                Button("Change flag") { flagFor = a.id }
                Button("Sign in again") { model.signIn(a.id) }
                Divider()
                if a.isPrimary { Button("Sign out") { signOut = true } }
                else { Button("Remove \(a.name)", role: .destructive) { removing = a } }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Options for \(a.name)")
        }
        .padding(.vertical, 4)
        .popover(isPresented: Binding(get: { flagFor == a.id }, set: { if !$0 { flagFor = nil } })) {
            FlagGrid(flag: Binding(get: { a.flag }, set: { model.setFlag(a.id, $0); flagFor = nil }), used: used)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Account name", text: $newName).textFieldStyle(.roundedBorder)
                Button { showNewFlags = true } label: { FlagView(flag: newFlag, size: 16) }.buttonStyle(.borderless)
                    .popover(isPresented: $showNewFlags) { FlagGrid(flag: Binding(get: { newFlag }, set: { newFlag = $0; showNewFlags = false }), used: used) }
                    .accessibilityLabel("Flag \(newFlag.letter)")
            }
            HStack {
                Button("Cancel") { adding = false }
                Spacer()
                Button("Sign in with browser") {
                    model.addAccount(name: newName.trimmingCharacters(in: .whitespaces), flag: newFlag)
                    adding = false
                }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.controlSize(.small).padding(12)
    }
}

struct RemoveSheet: View {
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
