import SwiftUI
import AppKit

@main enum Entry {
    static func main() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--snapshot"), a.indices.contains(i + 1) {
            MainActor.assumeIsolated { Snapshot.run(prefix: a[i + 1]) }
            exit(0)
        }
        if let i = a.firstIndex(of: "--brag-assets"), a.indices.contains(i + 1) {
            MainActor.assumeIsolated { BragAssets.run(dir: a[i + 1]) }
            exit(0)
        }
        AnchorApp.main()
    }
}

extension AppModel {
    /// One model for the app's lifetime. SwiftUI may build `AnchorApp` more than once; a model per
    /// init would start duplicate scans and leave FSEvents pointing at freed models (it holds `self` unretained).
    static let shared: AppModel = { let m = AppModel(); m.start(); return m }()
}

@MainActor struct AnchorApp: App {
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(model)
        } label: {
            let p = model.active.flatMap { model.limits[$0.id]?.fiveHour?.percent }
            Image(nsImage: MenuBarIcon.image(percent: p))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Anchor glyph inside a ring whose sweep is the 5h utilization. Template, except red at 90% and up.
@MainActor enum MenuBarIcon {
    static func image(percent: Double?, ink: Color = .black, scale: CGFloat = 2) -> NSImage {
        let hot = (percent ?? 0) >= 90
        let ring = hot ? Color.signalRed : ink
        let view = ZStack {
            AnchorGlyph().stroke(ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 11)
            if let p = percent {
                Circle().stroke(ring.opacity(0.25), lineWidth: 1.5)
                Circle().trim(from: 0, to: max(0.02, min(1, p / 100)))
                    .stroke(ring, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(1).frame(width: 18, height: 18)
        let r = ImageRenderer(content: view)
        r.scale = scale
        let img = r.nsImage ?? NSImage(systemSymbolName: "anchor", accessibilityDescription: "Claude Anchor") ?? NSImage()
        img.isTemplate = !hot
        return img
    }
}

// MARK: snapshot mode (`--snapshot <prefix>`): renders the popover offscreen for visual QA

@MainActor enum Snapshot {
    static func run(prefix: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let three = fake(six: false), six = fake(six: true)
        shoot(three, dark: false, to: prefix + "-light.png")
        shoot(three, dark: true, to: prefix + "-dark.png")
        shoot(six, dark: false, to: prefix + "-six-light.png")
        shoot(six, dark: true, to: prefix + "-six-dark.png")
        shoot(empty(), dark: false, to: prefix + "-empty.png")
        shoot(signIn(), dark: false, to: prefix + "-signin.png")
        shoot(six, dark: false, to: prefix + "-accounts.png", view: AnyView(AccountsPane()))
        shoot(six, dark: false, to: prefix + "-rules.png", view: AnyView(RulesPane()))
        shoot(three, dark: false, to: prefix + "-settings.png", view: AnyView(SettingsPane()))
    }

    static func shoot(_ model: AppModel, dark: Bool, to path: String, view: AnyView? = nil) {
        let scheme: ColorScheme = dark ? .dark : .light
        let host = NSHostingView(rootView: (view ?? AnyView(PopoverView())).environment(model).environment(\.colorScheme, scheme).environment(\.snapshotMode, true))
        let size = NSSize(width: 340, height: host.fittingSize.height)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        win.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        win.orderOut(nil)
    }

    /// Models here never touch real files (`live = false`).
    static func blank() -> AppModel { let m = AppModel(); m.live = false; return m }

    /// Claude Code isn't installed.
    static func empty() -> AppModel {
        let m = blank()
        m.cliInstalled = false
        m.config.accounts = []
        return m
    }

    /// First run: the primary account exists but isn't signed in.
    static func signIn() -> AppModel {
        let m = blank()
        m.config.accounts = [Account(id: "primary", name: "Personal", flag: .p, dir: Paths.primaryDir, pending: true)]
        return m
    }

    static func fake(six: Bool) -> AppModel {
        let m = blank()
        let emails = ["primary": "you@work.example", "client": "you@client.example", "personal": "you@example.com",
                      "studio": "you@studio.example", "side": "you@example.com", "lab": "you@lab.example"]
        func acct(_ id: String, _ n: String, _ f: SignalFlag, _ plan: String, pending: Bool = false) -> Account {
            Account(id: id, name: n, flag: f, dir: id == "primary" ? Paths.primaryDir : Paths.accounts + "/" + id,
                    email: pending ? nil : emails[id], plan: plan, pending: pending)
        }
        var list = [acct("primary", "Work", .w, "pro"), acct("client", "Client", .c, "max"), acct("personal", "Personal", .p, "pro")]
        if six { list += [acct("studio", "Studio", .s, "pro"), acct("side", "Side project", .d, "max"), acct("lab", "Lab", .l, "pro", pending: true)] }
        m.config.accounts = list
        m.config.defaultID = six ? "studio" : "primary"
        let now = Date()
        func lim(_ a: Double, _ b: Double) -> Limits {
            Limits(fiveHour: LimitWindow(percent: a, resetsAt: now.addingTimeInterval(6000)),
                   weekly: LimitWindow(percent: b, resetsAt: now.addingTimeInterval(2 * 86_400)), fetchedAt: now)
        }
        m.limits = ["primary": lim(68, 31), "client": lim(22, 12), "personal": lim(5, 3), "studio": lim(93, 41)]
        if six { m.banner = "Switched to Studio. Work hit 92% of its 5h limit."; m.overflowSuggestion = "studio" }
        m.usageRows = [
            UsageRow(id: "primary", label: "Work", accountID: "primary", tokens: 1_240_000, outputTokens: 180_000, cost: 14.2),
            UsageRow(id: "client", label: "Client", accountID: "client", tokens: 640_000, outputTokens: 90_000, cost: 7.9),
            UsageRow(id: "personal", label: "Personal", accountID: "personal", tokens: 212_000, outputTokens: 30_000, cost: 2.35),
        ] + (six ? [
            UsageRow(id: "studio", label: "Studio", accountID: "studio", tokens: 48_000, outputTokens: 6_000, cost: 0.61),
            UsageRow(id: "side", label: "Side project", accountID: "side", tokens: 900, outputTokens: 100, cost: 0.02),
        ] : [])
        m.config.rules = [Rule(path: Paths.home + "/code/website", accountID: "primary"),
                          Rule(path: Paths.home + "/code/client-app", accountID: "client", allowOverflow: true),
                          Rule(path: Paths.home + "/notes", accountID: "personal")]
        m.lastSession = (cwd: Paths.home + "/code/website", accountID: "primary", file: "/x/s.jsonl")
        return m
    }
}

/// Anchor drawn by hand (SF Symbols has none): eye ring, shank, stock, curved arms with flukes.
struct AnchorGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, x = r.midX
        p.addEllipse(in: CGRect(x: x - w * 0.14, y: r.minY, width: w * 0.28, height: w * 0.28))     // eye
        p.move(to: CGPoint(x: x, y: r.minY + w * 0.28)); p.addLine(to: CGPoint(x: x, y: r.maxY))   // shank
        p.move(to: CGPoint(x: x - w * 0.3, y: r.minY + h * 0.36))                                    // stock
        p.addLine(to: CGPoint(x: x + w * 0.3, y: r.minY + h * 0.36))
        p.move(to: CGPoint(x: r.minX, y: r.minY + h * 0.62))                                         // arms
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.62), control: CGPoint(x: x, y: r.maxY + h * 0.42))
        for (dx, sgn) in [(r.minX, 1.0), (r.maxX, -1.0)] {                                           // flukes
            p.move(to: CGPoint(x: dx, y: r.minY + h * 0.62))
            p.addLine(to: CGPoint(x: dx + sgn * w * 0.16, y: r.minY + h * 0.56))
        }
        return p
    }
}

// MARK: brag assets (`--brag-assets <dir>`): real UI renders for the launch video, demo data only

@MainActor enum BragAssets {
    static func png(_ path: String, _ rep: NSBitmapImageRep) { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }

    static func run(dir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = Snapshot.fake(six: false)
        Snapshot.shoot(m, dark: false, to: dir + "/popover-work.png")
        let hot = Snapshot.fake(six: false)
        hot.limits["primary"] = Limits(fiveHour: LimitWindow(percent: 92, resetsAt: Date().addingTimeInterval(6000)),
                                       weekly: LimitWindow(percent: 31, resetsAt: Date().addingTimeInterval(2 * 86_400)), fetchedAt: Date())
        hot.banner = "Switched to Personal. Work hit 92% of its 5h limit."; hot.overflowSuggestion = "personal"
        Snapshot.shoot(hot, dark: false, to: dir + "/popover-limit.png")
        Snapshot.shoot(m, dark: false, to: dir + "/rules.png", view: AnyView(RulesPane()))
        // dial alone, uniform sweep of lever positions 0.12...0.88 (Work centre is 1/6, Personal 5/6), dark, transparent, 4x
        let N = 200
        for k in 0..<N {
            dial(m, pos: 0.12 + 0.76 * Double(k) / Double(N - 1), to: String(format: "%@/dial-%03d.png", dir, k))
        }
        for p in [0, 25, 50, 75, 100] {
            icon(MenuBarIcon.image(percent: Double(p), ink: .white, scale: 4), dir + "/menubar-icon-\(p).png")
        }
        icon(MenuBarIcon.image(percent: 100, ink: .white, scale: 4), dir + "/menubar-icon-red.png")
    }

    static func icon(_ img: NSImage, _ path: String) {
        if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) { png(path, r) }
    }

    static func dial(_ m: AppModel, pos: Double, to path: String) {
        let host = NSHostingView(rootView: TelegraphView(previewPos: pos).environment(m).environment(\.colorScheme, .dark))
        let size = NSSize(width: 308, height: 156), S = 4
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua); win.isOpaque = false; win.backgroundColor = .clear
        win.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        win.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * S, pixelsHigh: Int(size.height) * S, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        png(path, rep)
        win.orderOut(nil)
    }
}
