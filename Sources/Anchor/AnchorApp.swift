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
        if a.contains("--self-test") {   // CI; build in debug so asserts fire
            UsageIndex.selfTest()
            AppModel.selfTest()
            exit(0)
        }
        MainActor.assumeIsolated { AnchorApp.main() }
    }
}

extension AppModel {
    /// One model for the app's lifetime. SwiftUI may build `AnchorApp` more than once; a model per
    /// init would start duplicate scans and leave FSEvents pointing at freed models (it holds `self` unretained).
    static let shared: AppModel = { let m = AppModel(); m.start(); return m }()
}

@MainActor struct AnchorApp: App {
    private let model = AppModel.shared

    init() {
        // After launch finishes, so the panel isn't built mid-startup; sync is idempotent, so a second pass
        // catches a config that loads a moment later.
        let m = AppModel.shared
        DispatchQueue.main.async { FloatingController.shared.sync(m) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { FloatingController.shared.sync(m) }
    }

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
/// Drawn with Core Graphics: ImageRenderer spins up a Metal pipeline, about 100 MB at launch for an 18 pt icon.
@MainActor enum MenuBarIcon {
    static func image(percent: Double?, ink: Color = .black, scale: CGFloat = 2) -> NSImage {
        let hot = (percent ?? 0) >= 90
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(18 * scale), pixelsHigh: Int(18 * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ns = NSGraphicsContext(bitmapImageRep: rep) else { return img }
        rep.size = size
        let cg = ns.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: 18); cg.scaleBy(x: 1, y: -1)   // y down, like the SwiftUI shapes
        cg.setLineCap(.round); cg.setLineJoin(.round)

        let inkC = NSColor(ink).cgColor
        cg.setStrokeColor(inkC); cg.setLineWidth(1.4)
        cg.addPath(AnchorGlyph().path(in: CGRect(x: 4, y: 3.5, width: 10, height: 11)).cgPath)
        cg.strokePath()

        if let p = percent {
            let ring = hot ? NSColor(Color.signalRed).cgColor : inkC
            let box = CGRect(x: 1, y: 1, width: 16, height: 16)
            cg.setLineWidth(1.5)
            cg.setStrokeColor(ring.copy(alpha: ring.alpha * 0.25) ?? ring)
            cg.strokeEllipse(in: box)
            // Starts at 12 o'clock and sweeps clockwise (y is down, so increasing angles run clockwise).
            let sweep = max(0.02, min(1, p / 100))
            var arc = Path()
            arc.addArc(center: CGPoint(x: 9, y: 9), radius: 8, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * sweep), clockwise: false)
            cg.setStrokeColor(ring)
            cg.addPath(arc.cgPath)
            cg.strokePath()
        }
        ns.flushGraphics()
        img.addRepresentation(rep)
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
        shoot(freshScenario(), dark: false, to: prefix + "-fresh.png")
        shoot(freshScenario(), dark: true, to: prefix + "-fresh-dark.png")
        shoot(six, dark: false, to: prefix + "-popout.png", view: AnyView(PopoverView(popout: true)), width: 400, height: 760)
        floating(prefix: prefix)
    }

    /// Floating button (calm, fresh, near-limit), its tooltip and the quick panel.
    static func floating(prefix: String, scale: Int = 2) {
        let calm = fake(six: false), hot = nearLimit(), fresh = freshScenario()
        for dark in [false, true] {
            let d = dark ? "-dark" : ""
            shoot(calm, dark: dark, to: prefix + "-floating\(d).png", view: AnyView(FloatingButtonView()), width: 72, height: 72, clear: true)
            shoot(hot, dark: dark, to: prefix + "-floating-hot\(d).png", view: AnyView(FloatingButtonView()), width: 72, height: 72, clear: true)
            shoot(fresh, dark: dark, to: prefix + "-floating-fresh\(d).png", view: AnyView(FloatingButtonView()), width: 72, height: 72, clear: true)
            shoot(fresh, dark: dark, to: prefix + "-floating-tip\(d).png", view: AnyView(FloatingTooltipView()), clear: true)
            shoot(fresh, dark: dark, to: prefix + "-quick\(d).png", view: AnyView(QuickPanelView().background(Clay.paper).clipShape(RoundedRectangle(cornerRadius: 16))), width: 280, clear: true)
        }
        shoot(hot, dark: false, to: prefix + "-quick-hot.png", view: AnyView(QuickPanelView().background(Clay.paper).clipShape(RoundedRectangle(cornerRadius: 16))), width: 280, clear: true)
    }

    static func shoot(_ model: AppModel, dark: Bool, to path: String, view: AnyView? = nil,
                      width: CGFloat = 340, height: CGFloat? = nil, clear: Bool = false) {
        let scheme: ColorScheme = dark ? .dark : .light
        let host = NSHostingView(rootView: (view ?? AnyView(PopoverView())).environment(model).environment(\.colorScheme, scheme).environment(\.snapshotMode, true))
        let size = NSSize(width: width, height: height ?? host.fittingSize.height)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if clear { win.isOpaque = false; win.backgroundColor = .clear }
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

    /// Three accounts, Work is the default; Personal has a full, untouched 5h window.
    static func freshScenario() -> AppModel {
        let m = fake(six: false)
        m.limits["personal"] = Limits(fiveHour: LimitWindow(percent: 0, resetsAt: nil),
                                      weekly: LimitWindow(percent: 3, resetsAt: Date().addingTimeInterval(2 * 86_400)), fetchedAt: Date())
        return m
    }

    /// Default account at 92% of its 5h window.
    static func nearLimit() -> AppModel {
        let m = fake(six: false)
        m.limits["primary"] = Limits(fiveHour: LimitWindow(percent: 92, resetsAt: Date().addingTimeInterval(1320)),
                                     weekly: LimitWindow(percent: 54, resetsAt: Date().addingTimeInterval(2 * 86_400)), fetchedAt: Date())
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
        // Personal is FRESH (unused 5h window), Studio is near its limit.
        m.limits = ["primary": lim(68, 31), "client": lim(22, 12), "personal": lim(0, 3), "studio": lim(93, 41)]
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
        m.lastSession = (cwd: Paths.home + "/code/website", accountID: "primary", file: "/x/s.jsonl", editor: false)
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
        for (dx, sgn) in [(r.minX, CGFloat(1)), (r.maxX, CGFloat(-1))] {                                           // flukes
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
        Snapshot.shoot(Snapshot.freshScenario(), dark: false, to: dir + "/popover-fresh.png")
        Snapshot.shoot(Snapshot.freshScenario(), dark: true, to: dir + "/popover-fresh-dark.png")
        Snapshot.shoot(m, dark: false, to: dir + "/popout.png", view: AnyView(PopoverView(popout: true)), width: 400, height: 760)
        Snapshot.floating(prefix: dir + "/floating")
        for p in [0, 25, 50, 75, 100] {
            icon(MenuBarIcon.image(percent: Double(p), ink: .white, scale: 4), dir + "/menubar-icon-\(p).png")
        }
        icon(MenuBarIcon.image(percent: 100, ink: .white, scale: 4), dir + "/menubar-icon-red.png")
    }

    static func icon(_ img: NSImage, _ path: String) {
        if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) { png(path, r) }
    }
}
