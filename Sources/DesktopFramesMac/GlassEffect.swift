import DesktopFramesCore
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
        case .clear: return L("A 清透", "A Clear")
        case .frosted: return L("B 磨砂", "B Frosted")
        case .dark: return L("C 暗色", "C Dark")
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

/// 玻璃边缘的光学细节（叠在系统液态玻璃上面的静态图层，画一次就不再重绘，不占 CPU）。
/// 思路来自 Glass 资料库里的开源实现，全部改写成原生 SwiftUI 形状（没有搬代码）：
/// - 受光边缘高光：随光照方向变化的边缘亮度（左上最亮、右下有一道反光）——参考 liquid-glass-react / liquid-glass（MIT）的“边缘高光”分层；
/// - 内侧倒角厚度：玻璃边缘内侧一圈柔和的亮带 + 底部一点暗边——参考 Glasswork（MIT）的 SDF 倒角；
/// - 边缘色散：亮边旁边一丝很淡的冷暖分色——参考 liquidGL / LiquidGlass（MIT）的色差；
/// - 细颗粒：极淡的磨砂颗粒——参考 Paper Shaders（Apache-2.0）的颗粒参数。
enum GlassEdge: String, CaseIterable, Identifiable {
    case classic, crystal, prism, slab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return L("原版（一圈细白边）", "Original (thin white rim)")
        case .crystal: return L("晶透：受光边缘高光", "Crystal: light-catching rim")
        case .prism: return L("棱镜：高光 + 淡淡色散", "Prism: rim + faint dispersion")
        case .slab: return L("厚玻璃：倒角厚度 + 细颗粒", "Slab: bevel depth + fine grain")
        }
    }
}

/// 全局外观设置（菜单栏“玻璃质感”）。只在用户切换时发布变化，平时不产生任何刷新。
@MainActor
final class GlassSettings: ObservableObject {
    static let shared = GlassSettings()
    static let defaultsKey = "GlassStyle"
    static let edgeDefaultsKey = "GlassEdge"

    @Published var style: GlassStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.defaultsKey) }
    }

    static let refractionDefaultsKey = "GlassRefraction"

    /// 折射：边缘拉伸（默认）/ 光栅玻璃 / 关。
    @Published var refraction: GlassRefraction {
        didSet { UserDefaults.standard.set(refraction.rawValue, forKey: Self.refractionDefaultsKey) }
    }

    @Published var edge: GlassEdge {
        didSet {
            UserDefaults.standard.set(edge.rawValue, forKey: Self.edgeDefaultsKey)
            LidLight.shared.setWanted(edge != .classic)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        style = raw.flatMap(GlassStyle.init(rawValue:)) ?? .clear
        refraction = UserDefaults.standard.string(forKey: Self.refractionDefaultsKey).flatMap(GlassRefraction.init(rawValue:)) ?? .edge
        let edgeRaw = UserDefaults.standard.string(forKey: Self.edgeDefaultsKey)
        edge = edgeRaw.flatMap(GlassEdge.init(rawValue:)) ?? .classic
        LidLight.shared.setWanted(edge != .classic)
    }
}

/// 玻璃边缘光学图层（静态）。只画在玻璃边缘一圈，不挡内容、不接收点击。
/// 跟着屏幕角度走的边缘光：只有这一小块视图订阅角度变化，分区里的图标列表不会跟着重算。
struct LidLitEdgeOverlay: View {
    let edge: GlassEdge
    let style: GlassStyle
    let cornerRadius: CGFloat
    @ObservedObject private var lid = LidLight.shared

    var body: some View {
        GlassEdgeOverlay(edge: edge, style: style, cornerRadius: cornerRadius, lightOffset: edge == .classic ? 0 : lid.offset)
    }
}

struct GlassEdgeOverlay: View {
    let edge: GlassEdge
    let style: GlassStyle
    let cornerRadius: CGFloat
    /// 高光沿边缘的偏移（度），来自屏幕角度；0 = 光从左上来。
    var lightOffset: Double = 0

    private var start: Angle { .degrees(lightOffset) }
    private var end: Angle { .degrees(360 + lightOffset) }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    /// 各质感下高光的整体强度：暗色玻璃上白光要收着，否则发灰。
    private var k: Double {
        switch style {
        case .clear: return 1.0
        case .frosted: return 1.5 // 磨砂底更亮更奶，高光要加强才看得出
        case .dark: return 0.5
        }
    }

    var body: some View {
        ZStack {
            switch edge {
            case .classic:
                // 1px 边缘高光（强度随质感），顶部再加一道内高光，模拟玻璃受光
                shape.strokeBorder(Color.white.opacity(style.rimAlpha), lineWidth: 1)
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(style.rimAlpha * 1.5), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
            case .crystal:
                bevel(strength: 0.6)
                specularRim
            case .prism:
                bevel(strength: 0.6)
                dispersion
                specularRim
            case .slab:
                bevel(strength: 1.25)
                grain
                specularRim
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 受光边缘：一圈 1pt 的亮边，亮度随方向变化（光从左上来）。
    /// SwiftUI 的角度从右侧 0° 顺时针增加：左上 = 225°，右下 = 45°。
    private var specularRim: some View {
        let stops: [(Double, Double)] = [
            (0, 0.16), (35, 0.42), (50, 0.50), (80, 0.14), (140, 0.12),
            (190, 0.40), (225, 0.95), (255, 0.62), (300, 0.20), (360, 0.16)
        ]
        let gradient = AngularGradient(
            stops: stops.map { .init(color: Color.white.opacity(min(1, $0.1 * k)), location: $0.0 / 360) },
            center: .center, startAngle: start, endAngle: end
        )
        return ZStack {
            // 左上边缘一圈柔光（光源方向），让受光的那条边真的“亮起来”
            shape.inset(by: 1.5)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 160.0 / 360),
                            .init(color: Color.white.opacity(min(1, 0.38 * k)), location: 225.0 / 360),
                            .init(color: Color.white.opacity(min(1, 0.18 * k)), location: 265.0 / 360),
                            .init(color: .clear, location: 310.0 / 360),
                            .init(color: .clear, location: 1)
                        ],
                        center: .center, startAngle: start, endAngle: end
                    ),
                    lineWidth: 3
                )
                .blur(radius: 2)
                .clipShape(shape)
            shape.strokeBorder(gradient, lineWidth: 1)
            // 左上角内侧再压一道更细更亮的“镜面”反光，边缘读起来像真的玻璃切面
            shape.inset(by: 1)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 185.0 / 360),
                            .init(color: Color.white.opacity(min(1, 0.85 * k)), location: 228.0 / 360),
                            .init(color: .clear, location: 275.0 / 360),
                            .init(color: .clear, location: 1)
                        ],
                        center: .center, startAngle: start, endAngle: end
                    ),
                    lineWidth: 0.75
                )
                .blur(radius: 0.4)
        }
    }

    /// 内侧倒角：边缘往里一圈很柔的亮带（上亮下淡）+ 底边一丝暗线，给玻璃“厚度”。
    private func bevel(strength: Double) -> some View {
        ZStack {
            shape.inset(by: 1)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.22 * strength * k), location: 0),
                            .init(color: Color.white.opacity(0.06 * strength * k), location: 0.45),
                            .init(color: Color.white.opacity(0.10 * strength * k), location: 1)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 5
                )
                .blur(radius: 3)
            shape.inset(by: 1.5)
                .stroke(
                    LinearGradient(colors: [.clear, .clear, Color.black.opacity(0.10 * strength)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .blur(radius: 0.8)
        }
        .clipShape(shape)
    }

    /// 边缘色散：亮边内侧一丝冷色（左上）和暖色（右下），像光穿过玻璃边缘被轻轻分开。
    private var dispersion: some View {
        let cool = Color(red: 0.55, green: 0.85, blue: 1.0)
        let warm = Color(red: 1.0, green: 0.62, blue: 0.80)
        let gradient = AngularGradient(
            stops: [
                .init(color: warm.opacity(0.0), location: 0),
                .init(color: warm.opacity(0.55 * k), location: 45.0 / 360),
                .init(color: warm.opacity(0.0), location: 110.0 / 360),
                .init(color: cool.opacity(0.0), location: 170.0 / 360),
                .init(color: cool.opacity(0.60 * k), location: 230.0 / 360),
                .init(color: cool.opacity(0.0), location: 300.0 / 360),
                .init(color: warm.opacity(0.0), location: 1)
            ],
            center: .center, startAngle: start, endAngle: end
        )
        return shape.inset(by: 1.5)
            .stroke(gradient, lineWidth: 1.5)
            .blur(radius: 0.6)
            .blendMode(.plusLighter)
            .clipShape(shape)
    }

    /// 细颗粒：一张 96×96 的随机颗粒小图平铺（只生成一次），透明度很低。
    private var grain: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(decorative: GrainTile.image, scale: 2)))
            .opacity(style == .dark ? 0.03 : 0.035)
            .blendMode(.overlay)
            .clipShape(shape)
    }
}

/// 颗粒贴图：启动后第一次用到时生成一次，之后共用（约 36KB）。
enum GrainTile {
    nonisolated(unsafe) static let image: CGImage = {
        let side = 96
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(side * side) {
            // 固定种子的伪随机（每次启动颗粒一致，不闪）
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8(truncatingIfNeeded: seed >> 56)
            bytes[i * 4] = v
            bytes[i * 4 + 1] = v
            bytes[i * 4 + 2] = v
            bytes[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }()
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
