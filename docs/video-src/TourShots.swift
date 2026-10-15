// Dropped into a scratch copy of Sources/Anchor by make-assets.sh (never compiled in the app).
// Renders the extra demo-data states the tour needs, at 2x, via `Anchor --tour-assets <dir>`.
import SwiftUI
import AppKit

@MainActor enum TourShots {
    static func model(anchor: String = "primary", personal5h: Double = 0) -> AppModel {
        let m = Snapshot.fake(six: false)
        m.config.defaultID = anchor
        m.limits["personal"] = Limits(fiveHour: LimitWindow(percent: personal5h, resetsAt: personal5h > 0 ? Date().addingTimeInterval(16_000) : nil),
                                      weekly: LimitWindow(percent: 3, resetsAt: Date().addingTimeInterval(2 * 86_400)), fetchedAt: Date())
        m.lastRefreshed = Date()
        return m
    }

    static func run(dir: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let quick = { AnyView(QuickPanelView().background(Clay.paper).clipShape(RoundedRectangle(cornerRadius: 16))) }
        // Work anchored, Personal fresh / Personal anchored (after the switch)
        for (name, m) in [("work", model()), ("personal", model(anchor: "personal")), ("calm", model(personal5h: 4))] {
            Snapshot.shoot(m, dark: false, to: "\(dir)/home-\(name).png")
            Snapshot.shoot(m, dark: false, to: "\(dir)/quick-\(name).png", view: quick(), width: 280, clear: true)
            Snapshot.shoot(m, dark: false, to: "\(dir)/button-\(name).png", view: AnyView(FloatingButtonView()), width: 72, height: 72, clear: true)
        }
        Snapshot.shoot(model(), dark: true, to: "\(dir)/home-work-dark.png")
        Snapshot.shoot(model(), dark: false, to: "\(dir)/popout.png", view: AnyView(PopoverView(popout: true)), width: 400)
        Snapshot.shoot(model(), dark: false, to: "\(dir)/tip.png", view: AnyView(FloatingTooltipView()), clear: true)
        BragAssets.icon(MenuBarIcon.image(percent: 68, ink: .black, scale: 4), "\(dir)/menubar-icon.png")
        let six = Snapshot.fake(six: true)
        Snapshot.shoot(six, dark: false, to: "\(dir)/accounts.png", view: AnyView(AccountsPane()))
        Snapshot.shoot(six, dark: false, to: "\(dir)/rules.png", view: AnyView(RulesPane()))
        Snapshot.shoot(model(), dark: false, to: "\(dir)/settings.png", view: AnyView(SettingsPane()))
    }
}
