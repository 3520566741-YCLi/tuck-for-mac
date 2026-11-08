import AppKit
import Combine
import SwiftUI

/// 三种玻璃质感（全局设置，三选一，切换即时生效）。
/// - clear   A 清透（默认）：系统 Liquid Glass 的 clear 样式，不着色，壁纸几乎完整透出。
/// - frosted B 磨砂：regular 样式 + 约 18% 白色着色，背后只剩色块。
/// - dark    C 暗色：regular 样式 + 深色着色，适合亮壁纸。
enum GlassStyle: String, CaseIterable, Identifiable {
    case clear, frosted, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: return "A 清透"
        case .frosted: return "B 磨砂"
        case .dark: return "C 暗色"
        }
    }

    /// 玻璃自身着色（nil = 不着色）。
    var glassTint: NSColor? {
        switch self {
        case .clear: return nil
        case .frosted: return NSColor(white: 1, alpha: 0.18)
        case .dark: return NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 28 / 255, alpha: 0.38)
        }
    }

    /// 1px 边缘高光的不透明度。
    var rimAlpha: Double {
        switch self {
        case .clear: return 0.42
        case .frosted: return 0.50
        case .dark: return 0.18
        }
    }

    /// 分区内文字配色：清透与暗色都用浅色字（清透靠文字阴影托住可读性）。
    var colorScheme: ColorScheme? {
        switch self {
        case .clear, .dark: return .dark
        case .frosted: return nil // 跟随系统
        }
    }

    /// 文字阴影强度（仅清透需要）。
    var textShadowAlpha: Double { self == .clear ? 0.45 : 0 }

    /// 旧系统（无 NSGlassEffectView）回退用的毛玻璃材质。
    var fallbackMaterial: NSVisualEffectView.Material {
        switch self {
        case .clear, .dark: return .hudWindow
        case .frosted: return .popover
        }
    }
}

/// 全局外观设置（菜单栏“玻璃质感”）。只在用户切换时发布变化，平时不产生任何刷新。
@MainActor
final class GlassSettings: ObservableObject {
    static let shared = GlassSettings()
    static let defaultsKey = "GlassStyle"

    @Published var style: GlassStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.defaultsKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        style = raw.flatMap(GlassStyle.init(rawValue:)) ?? .clear
    }
}

/// 苹果官方“液态玻璃”底板：macOS 26 起使用 NSGlassEffectView（WindowServer 合成，
/// 不自己写着色器，静止时不重绘），旧系统回退到 NSVisualEffectView 毛玻璃。
///
/// 圆角由玻璃自身 cornerRadius 控制；外层 SwiftUI 的 clipShape 用相同半径裁内容。
struct GlassEffect: NSViewRepresentable {
    var cornerRadius: CGFloat = 24
    var style: GlassStyle = .clear

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            apply(to: glass)
            return glass
        }
        let fallback = NSVisualEffectView()
        apply(to: fallback)
        return fallback
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    /// 只在值真的变化时才写属性，避免无谓的重新合成。
    private func apply(to view: NSView) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            let target: NSGlassEffectView.Style = (style == .clear) ? .clear : .regular
            if glass.style != target { glass.style = target }
            if glass.cornerRadius != cornerRadius { glass.cornerRadius = cornerRadius }
            if glass.tintColor != style.glassTint { glass.tintColor = style.glassTint }
        } else if let vev = view as? NSVisualEffectView {
            vev.material = style.fallbackMaterial
            vev.blendingMode = .behindWindow
            vev.state = .followsWindowActiveState
            vev.wantsLayer = true
            vev.layer?.cornerRadius = cornerRadius
            vev.layer?.masksToBounds = true
        }
    }
}
