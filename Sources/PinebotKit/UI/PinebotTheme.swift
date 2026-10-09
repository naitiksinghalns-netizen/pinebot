import SwiftUI
import AppKit

/// Semantic adaptive design system for Pinebot.
/// Adheres strictly to the warm ivory/canvas palette with graceful dark-mode counterparts.
public struct PinebotTheme {
    
    // MARK: - Spacing
    public static let space4: CGFloat = 4.0
    public static let space6: CGFloat = 6.0
    public static let space8: CGFloat = 8.0
    public static let space12: CGFloat = 12.0
    public static let space16: CGFloat = 16.0
    public static let space24: CGFloat = 24.0
    
    // MARK: - Corner Radii
    public static let radiusOuter: CGFloat = 16.0
    public static let radiusCard: CGFloat = 12.0
    public static let radiusControl: CGFloat = 10.0
    public static let radiusPill: CGFloat = 999.0
    
    // MARK: - Companion Buddy Layout
    public static let buddyPadding: CGFloat = 18.0
    public static let buddyDragThreshold: CGFloat = 4.0
    
    // MARK: - Typography
    public static let fontHeading = Font.system(size: 22, weight: .semibold, design: .default)
    public static let fontTitle = Font.system(size: 15, weight: .semibold, design: .default)
    public static let fontBody = Font.system(size: 13, weight: .regular, design: .default)
    public static let fontBodyMedium = Font.system(size: 13, weight: .medium, design: .default)
    public static let fontCaption = Font.system(size: 11, weight: .regular, design: .default)
    public static let fontCaptionMedium = Font.system(size: 11, weight: .medium, design: .default)
    public static let fontMonospace = Font.system(size: 12, weight: .regular, design: .monospaced)
    
    // MARK: - Semantic Colors (Adaptive Light & Dark)
    
    /// Background Canvas: Light #F7F6F2, Dark #181A18
    public static var canvas: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0x18/255.0, green: 0x1A/255.0, blue: 0x18/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0xF7/255.0, green: 0xF6/255.0, blue: 0xF2/255.0, alpha: 1.0)
            }
        }))
    }
    
    /// Card / Container Surface: Light #FFFFFF, Dark #222522
    public static var surface: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0x22/255.0, green: 0x25/255.0, blue: 0x22/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            }
        }))
    }
    
    /// Secondary Surface (Hover, chips, controls): Light #EEEEAA/0.5, Dark #2A2D2A
    public static var surfaceSubtle: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0x2A/255.0, green: 0x2D/255.0, blue: 0x2A/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0xEE/255.0, green: 0xED/255.0, blue: 0xE6/255.0, alpha: 1.0)
            }
        }))
    }
    
    /// Primary Text: Light #20251F, Dark #ECEEEA
    public static var textPrimary: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0xEC/255.0, green: 0xEE/255.0, blue: 0xEA/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0x20/255.0, green: 0x25/255.0, blue: 0x1F/255.0, alpha: 1.0)
            }
        }))
    }
    
    /// Secondary Text: Light #6D736B, Dark #9FA59D
    public static var textSecondary: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0x9F/255.0, green: 0xA5/255.0, blue: 0x9D/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0x6D/255.0, green: 0x73/255.0, blue: 0x6B/255.0, alpha: 1.0)
            }
        }))
    }
    
    /// Restrained Amber Accent: Light #D99320, Dark #EAA53B
    public static var amber: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0xEA/255.0, green: 0xA5/255.0, blue: 0x3B/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0xD9/255.0, green: 0x93/255.0, blue: 0x20/255.0, alpha: 1.0)
            }
        }))
    }
    
    /// Restrained Leaf Green Accent: Light #46714B, Dark #5E8F64
    public static var green: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0x5E/255.0, green: 0x8F/255.0, blue: 0x64/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0x46/255.0, green: 0x71/255.0, blue: 0x4B/255.0, alpha: 1.0)
            }
        }))
    }
    
    /// Border / Separator: Light #E5E7DE, Dark #2F332E
    public static var separator: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0x2F/255.0, green: 0x33/255.0, blue: 0x2E/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0xE5/255.0, green: 0xE7/255.0, blue: 0xDE/255.0, alpha: 1.0)
            }
        }))
    }
    
    /// Subtle Red for Stop / Failures: Light #BA3B34, Dark #D9544D
    public static var error: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: 0xD9/255.0, green: 0x54/255.0, blue: 0x4D/255.0, alpha: 1.0)
            } else {
                return NSColor(srgbRed: 0xBA/255.0, green: 0x3B/255.0, blue: 0x34/255.0, alpha: 1.0)
            }
        }))
    }
}
