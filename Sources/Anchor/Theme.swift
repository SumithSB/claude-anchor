import SwiftUI
import AppKit

/// "Clay" palette: warm paper and charcoal surfaces with a clay-orange accent.
/// Inspired by Claude's look; not Anthropic branding. Every colour adapts to light and dark.
enum Clay {
    // Accent
    static let accent = Color.dynamic(light: 0xD97757, dark: 0xD97757)       // marks, rings, selected borders
    static let accentText = Color.dynamic(light: 0xB5532F, dark: 0xEB9475)   // accent-coloured text (4.5:1 on surfaces)
    static let accentFill = Color.dynamic(light: 0xB9583A, dark: 0xD97757)   // filled button background
    static let accentInk = Color.dynamic(light: 0xFFFFFF, dark: 0x1D1C1A)    // text on accentFill
    // Surfaces
    static let paper = Color.dynamic(light: 0xF5F3EE, dark: 0x1D1C1A)        // window background
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x272624)      // cards
    static let surface2 = Color.dynamic(light: 0xF0EDE6, dark: 0x302E2B)     // inset wells, segmented controls
    static let hairline = Color.primary.opacity(0.10)
    // Status
    static let fresh = Color.dynamic(light: 0x2F7F6F, dark: 0x72C2AF)        // full 5h window available
    static let freshInk = Color.dynamic(light: 0xFFFFFF, dark: 0x1D1C1A)     // text on a fresh-coloured fill
    static let amber = Color.dynamic(light: 0x9A6A0E, dark: 0xE8BA5A)        // 75% and up
    static let limit = Color.dynamic(light: 0xB5352E, dark: 0xF27D72)        // 90% and up
    // Harbor scene
    static let sky = Color.dynamic(light: 0xFBF9F5, dark: 0x24231F)
    static let sea = Color.dynamic(light: 0xDDEAE8, dark: 0x1F2E2D)
    static let foam = Color.dynamic(light: 0xFFFFFF, dark: 0x3C5654)
    static let seabed = Color.dynamic(light: 0xEBD3C6, dark: 0x3A2A22)
    static let chain = Color.dynamic(light: 0x8A7F72, dark: 0x8F877C)

    enum Level { case ok, warn, crit }
    static func level(_ percent: Double) -> Level { percent >= 90 ? .crit : percent >= 75 ? .warn : .ok }

    /// Solid colour for a utilization percentage (text, small bars).
    static func color(_ percent: Double) -> Color {
        switch level(percent) { case .ok: return fresh; case .warn: return amber; case .crit: return limit }
    }

    /// Gradient for rings and bars: teal when fine, amber near the limit, red at it.
    static func gradient(_ percent: Double) -> LinearGradient {
        let pair: (Color, Color)
        switch level(percent) {
        case .ok: pair = (Color.dynamic(light: 0x5FB3A1, dark: 0x9ADBCB), Color.dynamic(light: 0x2F7F6F, dark: 0x4FA593))
        case .warn: pair = (Color.dynamic(light: 0xE9BE5C, dark: 0xF4D488), Color.dynamic(light: 0xB07A12, dark: 0xD9A23A))
        case .crit: pair = (Color.dynamic(light: 0xE57A70, dark: 0xFFA59C), Color.dynamic(light: 0xB5352E, dark: 0xE0564D))
        }
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
