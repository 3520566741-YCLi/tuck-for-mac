import AppKit
import Combine
import DesktopFramesCore
import ImageIO
import SwiftUI

/// 玻璃折射层：边缘拉伸 / 光栅（长虹）玻璃。
///
/// 真的“拉伸玻璃后面的东西”通常要录屏幕（费电、要隐私权限）。但分区窗口在桌面层，后面基本就是壁纸，
/// 所以直接读壁纸图片，把分区后面那一块按真实玻璃的方式重新采样：
/// - 边缘拉伸：靠近边缘的一圈从更里面取像素（像玻璃边缘把光弯折过来，边缘处的背景被拉长）；
/// - 光栅玻璃：一条条竖棱，每条棱像一根小柱面透镜，把背后的画面左右翻折、压缩。
/// 光学计算见 GlassOptics（斯涅尔折射、色散、按法线算的高光，原生重写，没有搬代码）。
///
/// 只在分区移动结束、改大小、换壁纸、切换空间时在后台算一次，静止时零耗电；普通图片壁纸不需要任何权限。
/// 系统动态 / 航拍壁纸读不到真实画面：用户在菜单里打开「动态壁纸也折射」后改为只截壁纸层（见 WallpaperCapture，
/// 要录屏权限）；没打开或没权限就自动不显示，什么都不影响。
enum GlassRefraction: String, CaseIterable, Identifiable {
    case off, edge, fluted
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return L("关闭", "Off")
        case .edge: return L("边缘拉伸（像真玻璃的边）", "Edge stretch (like a real glass edge)")
        case .fluted: return L("光栅玻璃（长虹竖棱）", "Fluted glass (vertical ribs)")
        }
    }
}

/// 折射层的全局开关状态（偷看模式时暂停：那时分区后面是别的窗口，不是壁纸）。
@MainActor
final class RefractionState: ObservableObject {
    static let shared = RefractionState()
    @Published var suspended = false
    /// 壁纸 / 空间变化时加一，让各分区重新算。
    @Published private(set) var revision = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RefractionState.shared.bump() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RefractionState.shared.bump() }
        })
        // 系统设置里换壁纸时会发这个分布式通知（没有公开常量，收不到也只是要等下次移动 / 切空间才更新）
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.desktop"), object: "BackgroundChanged", queue: .main) { _ in
            MainActor.assumeIsolated { RefractionState.shared.bump() }
        })
    }

    func bump() {
        WallpaperCache.shared.clear()
        revision &+= 1
    }
}

/// 分区玻璃里的折射层视图：后台算好一张图，算好之前 / 位置变了就先隐藏，不会错位。
struct RefractionLayer: View {
    let zoneID: UUID
    let frameKey: ZoneFrame
    let mode: GlassRefraction
    let style: GlassStyle
    let cornerRadius: CGFloat
    let manager: ZoneWindowManager
    @ObservedObject private var state = RefractionState.shared
    /// hasBackdrop = false：这一次读不到壁纸（动态壁纸没开截壁纸层 / 没授权），光栅模式只画出竖棱的明暗，不会“选了没变化”。
    @State private var rendered: (key: RenderKey, image: CGImage, hasBackdrop: Bool)?

    struct RenderKey: Equatable {
        var frame: ZoneFrame
        var mode: GlassRefraction
        var radius: CGFloat
        var style: GlassStyle
        var revision: Int
    }

    private var key: RenderKey { RenderKey(frame: frameKey, mode: mode, radius: cornerRadius, style: style, revision: state.revision) }

    var body: some View {
        ZStack {
            if mode != .off, !state.suspended, let rendered, rendered.key == key {
                Image(decorative: rendered.image, scale: rendered.image.width > 0 ? CGFloat(rendered.image.width) / max(1, frameKey.width) : 2)
                    .resizable()
                    // 磨砂 / 暗色已经在 GlassOptics 里先糊过背景再折射（棱和倒角的形状保持清楚），这里只盖同样的色调
                    .overlay { if rendered.hasBackdrop { tint } }
                    // 光栅的竖棱会让标题栏的小图标发花：顶部压一层很淡的暗色，标题栏文字和按钮更清楚
                    .overlay(alignment: .top) {
                        if mode == .fluted, rendered.hasBackdrop {
                            LinearGradient(colors: [Color.black.opacity(style == .dark ? 0.10 : 0.16), .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 60)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: rendered?.key == key)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: key) {
            guard mode != .off, !state.suspended else { return }
            try? await Task.sleep(for: .milliseconds(150)) // 拖动 / 缩放中不算，停下来再算
            guard !Task.isCancelled else { return }
            let source = manager.refractionSource(for: zoneID)
            let job = RefractionJob(frame: source?.frame ?? CGRect(x: 0, y: 0, width: frameKey.width, height: frameKey.height),
                                    screen: source?.screen, scale: source?.scale ?? (NSScreen.main?.backingScaleFactor ?? 2),
                                    mode: mode, radius: cornerRadius, frosted: style != .clear)
            let result = await Task.detached(priority: .utility) { await job.render() }.value
            guard !Task.isCancelled else { return }
            rendered = result.map { (key, $0.image, $0.hasBackdrop) }
        }
    }

    /// 磨砂 / 暗色质感下给折射层盖一层和玻璃同样的色调，不然边缘会比玻璃本体“清”。
    @ViewBuilder private var tint: some View {
        switch style {
        case .clear: Color.clear
        case .frosted: Color.white.opacity(0.32)
        case .dark: Color(red: 18 / 255, green: 18 / 255, blue: 28 / 255).opacity(0.42)
        }
    }
}

/// 后台渲染所需的全部输入（值类型，可跨线程）。
struct RefractionSource {
    let frame: CGRect          // 分区窗口在全局坐标里的位置（点）
    let screen: ScreenInfo
    let scale: CGFloat
}

struct ScreenInfo: Sendable {
    let frame: CGRect
    /// 壁纸图片文件；动态壁纸走截图时为 nil。
    let wallpaper: URL?
    let scaling: NSImageScaling
    let allowClipping: Bool
    /// 不为 nil：从这块屏幕截壁纸层（动态壁纸，用户打开了「动态壁纸也折射」）。
    var captureDisplay: CGDirectDisplayID? = nil
}

struct RefractionJob: Sendable {
    let frame: CGRect
    /// nil = 读不到壁纸
    let screen: ScreenInfo?
    let scale: CGFloat
    let mode: GlassRefraction
    let radius: CGFloat
    let frosted: Bool

    func render() async -> (image: CGImage, hasBackdrop: Bool)? {
        let optics: GlassOptics.Mode = mode == .fluted ? .fluted : .edge
        guard mode != .off else { return nil }
        var backdrop: CGImage?
        if let screen {
            if let display = screen.captureDisplay {
                if let full = await WallpaperCapture.capture(displayID: display, screenFrame: screen.frame, scale: scale) {
                    backdrop = WallpaperCache.compose(full, scaling: .scaleAxesIndependently, allowClipping: true, screenFrame: screen.frame, region: frame, scale: scale)
                }
            } else {
                backdrop = WallpaperCache.shared.backdrop(screen: screen, region: frame, scale: scale)
            }
        }
        let w = backdrop?.width ?? Int((frame.width * scale).rounded())
        let h = backdrop?.height ?? Int((frame.height * scale).rounded())
        guard w * h < 40_000_000 else { return nil }
        guard let image = GlassOptics.render(backdrop: backdrop, width: w, height: h, mode: optics, params: .current,
                                             radius: radius * scale, scale: scale, frosted: frosted) else { return nil }
        return (image, backdrop != nil)
    }
}

// MARK: - 壁纸读取与裁切

/// 壁纸解码缓存：解码一次留 20 秒（同时移动几个分区时共用），之后自动释放，平时不占内存。
final class WallpaperCache: @unchecked Sendable {
    static let shared = WallpaperCache()
    private let lock = NSLock()
    private var entry: (url: URL, pixelSize: CGSize, image: CGImage, at: Date)?

    func clear() {
        lock.lock(); entry = nil; lock.unlock()
    }

    /// 把壁纸按系统的摆放方式（填充 / 适应 / 拉伸 / 居中）映射到屏幕，裁出 region 那一块（像素）。
    func backdrop(screen: ScreenInfo, region: CGRect, scale: CGFloat) -> CGImage? {
        let screenPixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        guard let url = screen.wallpaper, let wallpaper = load(url, fitting: screenPixels) else { return nil }
        return Self.compose(wallpaper, scaling: screen.scaling, allowClipping: screen.allowClipping, screenFrame: screen.frame, region: region, scale: scale)
    }

    static func compose(_ wallpaper: CGImage, scaling: NSImageScaling, allowClipping: Bool, screenFrame: CGRect, region: CGRect, scale: CGFloat) -> CGImage? {
        let screenPixels = CGSize(width: screenFrame.width * scale, height: screenFrame.height * scale)
        let iw = CGFloat(wallpaper.width), ih = CGFloat(wallpaper.height)
        // 图片在屏幕上的摆放矩形（屏幕像素坐标，原点左上）
        var placed: CGRect
        switch scaling {
        case .scaleAxesIndependently:
            placed = CGRect(origin: .zero, size: screenPixels)
        case .scaleNone:
            placed = CGRect(x: (screenPixels.width - iw) / 2, y: (screenPixels.height - ih) / 2, width: iw, height: ih)
        default: // 按比例：允许裁切 = 填充，不允许 = 适应
            let sx = screenPixels.width / iw, sy = screenPixels.height / ih
            let s = allowClipping ? max(sx, sy) : min(sx, sy)
            placed = CGRect(x: (screenPixels.width - iw * s) / 2, y: (screenPixels.height - ih * s) / 2, width: iw * s, height: ih * s)
        }
        // 分区在屏幕里的位置（像素，原点左上）
        let local = CGRect(
            x: (region.minX - screenFrame.minX) * scale,
            y: (screenFrame.maxY - region.maxY) * scale,
            width: region.width * scale, height: region.height * scale
        ).integral
        guard local.width >= 8, local.height >= 8, local.width * local.height < 40_000_000 else { return nil }
        // 画出这一块：先铺黑（适应模式留边处），再把壁纸按摆放矩形画上去
        guard let ctx = CGContext(data: nil, width: Int(local.width), height: Int(local.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: local.size))
        ctx.interpolationQuality = .high
        // CGContext 原点在左下：把“左上原点”的矩形翻过来
        let draw = CGRect(x: placed.minX - local.minX, y: local.maxY - placed.maxY, width: placed.width, height: placed.height)
        ctx.draw(wallpaper, in: draw)
        return ctx.makeImage()
    }

    private func load(_ url: URL, fitting size: CGSize) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let e = entry, e.url == url, e.pixelSize == size, Date().timeIntervalSince(e.at) < 20 { return e.image }
        entry = nil
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        // 直接解码成接近屏幕的尺寸（壁纸常常 6K，按原图解码太占内存）
        let maxSide = max(size.width, size.height) * 1.1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        entry = (url, size, image, Date())
        // 过期后主动释放解码好的壁纸（几十 MB），平时不占内存
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 21) { [weak self] in self?.purgeExpired() }
        return image
    }

    private func purgeExpired() {
        lock.lock(); defer { lock.unlock() }
        if let e = entry, Date().timeIntervalSince(e.at) >= 20 { entry = nil }
    }
}
