import AppKit
import GaryCore
import SwiftUI

extension Color {
    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension NSColor {
    convenience init(_ rgba: RGBA) {
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

extension EdgeInsets {
    init(_ insets: Insets) {
        self.init(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }
}

extension HorizontalAlignment {
    init(_ align: Align) {
        switch align {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        }
    }
}

extension TextAlignment {
    init(_ align: Align) {
        switch align {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        }
    }
}

extension Text.TruncationMode {
    init(_ truncation: Truncation) {
        switch truncation {
        case .tail: self = .tail
        case .middle: self = .middle
        case .head: self = .head
        }
    }
}

extension Font.Weight {
    init(_ weight: FontToken.Weight) {
        switch weight {
        case .ultralight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        }
    }
}

extension NSFont.Weight {
    init(_ weight: FontToken.Weight) {
        switch weight {
        case .ultralight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        }
    }
}

private var fonts: [FontToken: NSFont] = [:]

func nsFont(_ token: FontToken) -> NSFont {
    if let cached = fonts[token] {
        return cached
    }
    let weight = NSFont.Weight(token.weight)
    let size = CGFloat(token.size)
    let font: NSFont
    switch token.family {
    case .system:
        font = .systemFont(ofSize: size, weight: weight)
    case .monospaced:
        font = .monospacedSystemFont(ofSize: size, weight: weight)
    case let .named(family):
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        font = NSFont(descriptor: descriptor, size: size).flatMap { $0.familyName == family ? $0 : nil }
            ?? NSFont(name: family, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
    fonts[token] = font
    return font
}

extension SwiftUI.Animation {
    init?(_ animation: GaryCore.Animation, duration: Double?) {
        switch animation {
        case .smooth: self = duration.map { .smooth(duration: $0) } ?? .smooth
        case .spring: self = duration.map { .spring(duration: $0) } ?? .spring
        case .instant: return nil
        }
    }
}

extension AnyTransition {
    init(_ transition: GaryCore.Transition) {
        switch transition {
        case .opacity: self = .opacity
        case .scale: self = .scale
        case .identity: self = .identity
        }
    }
}
