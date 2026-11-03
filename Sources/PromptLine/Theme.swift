import AppKit

/// Ghost Visor の配色。値の出所は dotfiles の colors/ghost-visor.toml(このリポジトリには写しだけを置く)。
enum Theme {
    static let background = NSColor(hex: 0x1A2340)    // core.background
    static let selectionBackground = NSColor(hex: 0x9385C8) // core.selection_bg
    static let selectionForeground = NSColor(hex: 0x0C1226) // core.selection_fg
    static let text = NSColor(hex: 0xCDE9F5)          // foregrounds.main
    static let dimText = NSColor(hex: 0xABA4C4)       // foregrounds.dim
    static let match = NSColor(hex: 0x58CAF8)         // ansi.cyan(検索語にかかった部分)
    static let caret = NSColor(hex: 0xC86FBE)         // ansi.magenta
    static let accent = selectionBackground

    // 背景のぼかしの上に重ねる色。透けさせるので不透明度を持つ
    static let glassTint = NSColor(hex: 0x1A2340, alpha: 0.72)
    static let sunkenTint = NSColor(hex: 0x0E142A, alpha: 0.38) // 履歴とフッターの帯
    static let hairline = NSColor(hex: 0xCDE9F5, alpha: 0.14)   // 区切り線と外周
    static let selectedRow = NSColor(hex: 0x9385C8, alpha: 0.26)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}
