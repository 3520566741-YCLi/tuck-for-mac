import CoreGraphics
import Foundation

/// 屏幕描述（从 NSScreen 提取后的纯值类型，便于在不依赖 AppKit 的环境下单测）。
public struct ScreenDescriptor: Sendable, Equatable {
    public let displayID: UInt32
    public let name: String
    /// 全屏区域（AppKit 全局坐标，原点在主屏左下角，y 向上）。
    public let frame: CGRect
    /// 可用区域（不含菜单栏 / Dock）。
    public let visibleFrame: CGRect

    public init(displayID: UInt32, name: String, frame: CGRect, visibleFrame: CGRect) {
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// 主屏判定：主屏 frame 的原点位于全局坐标 (0,0)。
    public var isPrimary: Bool { frame.origin == .zero }
}

/// 分区窗口坐标修正（阶段 A 第 5 项）。
///
/// 职责：
/// - 启动恢复：把分区放回其记录的屏幕，若记录缺失则回收到主屏。
/// - 分辨率变化 / 屏幕移除：把越界或超大的分区夹取回可见区域，绝不丢失在屏幕外。
/// 全部为纯函数，避免依赖 NSScreen 以便自动化测试。
public enum FrameSanitizer {

    // MARK: - ZoneFrame 便捷转换

    public static func cgRect(from frame: ZoneFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    public static func zoneFrame(from rect: CGRect) -> ZoneFrame {
        ZoneFrame(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }

    /// 分区与屏幕边缘保持的最小间距。
    public static let margin: CGFloat = 20
    /// 分区允许收缩到的最小尺寸（屏幕比它还小时按实际可用空间处理）。
    public static let minimumSize = CGSize(width: 120, height: 80)

    /// 主屏在 screens 中的下标；没有明显主屏时返回 0（前提是 screens 非空）。
    public static func primaryIndex(in screens: [ScreenDescriptor]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let i = screens.firstIndex(where: { $0.isPrimary }) { return i }
        return 0
    }

    /// 按显示器 ID 精确匹配；找不到返回 nil。
    public static func index(ofScreenWithID id: UInt32, in screens: [ScreenDescriptor]) -> Int? {
        screens.firstIndex { $0.displayID == id }
    }

    /// 解析布局中记录的 screenID 字符串（App 层写为十进制 CGDirectDisplayID）。
    public static func parseScreenID(_ raw: String?) -> UInt32? {
        guard let raw, !raw.isEmpty else { return nil }
        return UInt32(raw)
    }

    /// 把 frame 夹取进可见区域：超大则收缩，越界则平移，始终保留 margin 间距。
    /// 纯几何：当 visible 过小时退化为贴 margin 锚点，保证结果矩形不越界。
    public static func clamped(_ frame: CGRect, into visible: CGRect, margin: CGFloat = FrameSanitizer.margin) -> CGRect {
        guard !visible.isEmpty else { return frame }

        let usableWidth = max(visible.width - 2 * margin, 1)
        let usableHeight = max(visible.height - 2 * margin, 1)

        // 尺寸：优先保留原尺寸，过大才收缩；小窗口不放大。
        var size = frame.size
        size.width = min(size.width, usableWidth)
        size.height = min(size.height, usableHeight)
        size.width = max(size.width, min(FrameSanitizer.minimumSize.width, usableWidth))
        size.height = max(size.height, min(FrameSanitizer.minimumSize.height, usableHeight))

        let lowX = visible.minX + margin
        let highX = visible.maxX - margin - size.width
        let lowY = visible.minY + margin
        let highY = visible.maxY - margin - size.height

        let x: CGFloat
        if highX >= lowX {
            x = min(max(frame.minX, lowX), highX)
        } else {
            x = lowX // 可用宽度小于 2*margin：贴左缘，尺寸已被压缩到可用宽度
        }
        let y: CGFloat
        if highY >= lowY {
            y = min(max(frame.minY, lowY), highY)
        } else {
            y = lowY
        }

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 恢复一个分区窗口的位置与所在屏幕。
    ///
    /// - 记录的屏幕仍存在：夹取到该屏可见区域。
    /// - 记录缺失（如外接屏被拔掉）：整体回收至主屏，并夹取可见。
    /// - returns: 修正后的 frame，以及实际选中的屏幕下标（供调用方回写 zone.screenID）。
    public static func restoreZone(
        frame: CGRect,
        screenID: String?,
        screens: [ScreenDescriptor]
    ) -> (frame: CGRect, screenIndex: Int) {
        guard let primary = primaryIndex(in: screens), !screens.isEmpty else {
            return (frame, 0)
        }

        let chosenIndex: Int
        if let raw = parseScreenID(screenID), let hit = index(ofScreenWithID: raw, in: screens) {
            chosenIndex = hit
        } else {
            chosenIndex = primary
        }

        let visible = screens[chosenIndex].visibleFrame
        return (clamped(frame, into: visible), chosenIndex)
    }
}
