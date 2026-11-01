import AppKit

/// Ghost Visor の配色。値の出所は dotfiles の colors/ghost-visor.toml(このリポジトリには写しだけを置く)。
enum Theme {
    static let background = NSColor(hex: 0x1A2340)    // core.background
    static let sunkenBackground = NSColor(hex: 0x141B34) // core.sunken_bg
    static let activeLine = NSColor(hex: 0x2A3159)    // core.active_line
    static let selectionBackground = NSColor(hex: 0x9385C8) // core.selection_bg
    static let selectionForeground = NSColor(hex: 0x0C1226) // core.selection_fg
    static let text = NSColor(hex: 0xCDE9F5)          // foregrounds.main
    static let dimText = NSColor(hex: 0xABA4C4)       // foregrounds.dim
    static let border = NSColor(hex: 0x4C4C74)        // semantic border
    static let match = NSColor(hex: 0x58CAF8)         // ansi.cyan(検索語にかかった部分)
    static let caret = NSColor(hex: 0xC86FBE)         // ansi.magenta
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
