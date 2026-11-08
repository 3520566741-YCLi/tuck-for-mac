import CoreGraphics
import Foundation
import Testing
@testable import DesktopFramesCore

/// 构造一个测试屏幕。
/// - main: 主屏 frame 原点 (0,0)
/// - 外接屏可放在主屏右侧（frame.origin.x == 主屏宽度）
private func screen(
    id: UInt32,
    name: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    menuBarHeight: CGFloat = 25
) -> ScreenDescriptor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    let visible = CGRect(x: frame.minX, y: frame.minY, width: width, height: height - menuBarHeight)
    return ScreenDescriptor(displayID: id, name: name, frame: frame, visibleFrame: visible)
}

/// 常见双屏布局：主屏 1920x1080，右侧外接屏 2560x1440。
private func twoScreens() -> [ScreenDescriptor] {
    [
        screen(id: 1, name: "主显示器", x: 0, y: 0, width: 1920, height: 1080),
        screen(id: 2, name: "外接显示器", x: 1920, y: 0, width: 2560, height: 1440)
    ]
}

@Suite("FrameSanitizer 坐标修正")
struct ScreenLayoutTests {

    @Test("主屏判定：frame 原点为 (0,0)")
    func primaryDetection() throws {
        let screens = twoScreens()
        #expect(FrameSanitizer.primaryIndex(in: screens) == 0)
        #expect(screens[0].isPrimary)
        #expect(!screens[1].isPrimary)
    }

    @Test("按显示器 ID 精确匹配")
    func matchByDisplayID() throws {
        let screens = twoScreens()
        #expect(FrameSanitizer.index(ofScreenWithID: 2, in: screens) == 1)
        #expect(FrameSanitizer.index(ofScreenWithID: 99, in: screens) == nil)
        #expect(FrameSanitizer.parseScreenID("2") == 2)
        #expect(FrameSanitizer.parseScreenID("abc") == nil)
        #expect(FrameSanitizer.parseScreenID(nil) == nil)
    }

    @Test("分区在其屏幕内且不越界时保持原位置尺寸")
    func frameInsideScreenUntouched() throws {
        let screens = twoScreens()
        // 外接屏上（y 与主屏相同坐标系），位置在外接屏 visible 内。
        let frame = CGRect(x: 1920 + 100, y: 100, width: 420, height: 300)
        let result = FrameSanitizer.restoreZone(frame: frame, screenID: "2", screens: screens)
        #expect(result.screenIndex == 1)
        #expect(result.frame == frame)
    }

    @Test("完全落在屏幕外的分区被夹取回可见区域")
    func offscreenFrameClampedIn() throws {
        let screens = twoScreens()
        // 原本在外接屏上，但记录坐标早已超出（分辨率曾缩小）。
        let frame = CGRect(x: 8000, y: 8000, width: 420, height: 300)
        let result = FrameSanitizer.restoreZone(frame: frame, screenID: "2", screens: screens)
        let visible = screens[1].visibleFrame
        #expect(result.screenIndex == 1)
        #expect(result.frame.minX >= visible.minX + FrameSanitizer.margin - 0.001)
        #expect(result.frame.minY >= visible.minY + FrameSanitizer.margin - 0.001)
        #expect(result.frame.maxX <= visible.maxX - FrameSanitizer.margin + 0.001)
        #expect(result.frame.maxY <= visible.maxY - FrameSanitizer.margin + 0.001)
    }

    @Test("超大分区按可见区域收缩并保持边距")
    func oversizedFrameShrinks() throws {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let huge = CGRect(x: -500, y: -500, width: 4000, height: 3000)
        let result = FrameSanitizer.clamped(huge, into: visible)
        #expect(result.width <= 1920 - 2 * FrameSanitizer.margin + 0.001)
        #expect(result.height <= 1055 - 2 * FrameSanitizer.margin + 0.001)
        #expect(result.minX >= FrameSanitizer.margin - 0.001)
        #expect(result.minY >= FrameSanitizer.margin - 0.001)
        #expect(result.maxX <= visible.maxX - FrameSanitizer.margin + 0.001)
        #expect(result.maxY <= visible.maxY - FrameSanitizer.margin + 0.001)
    }

    @Test("小窗口不被放大，只在越界时平移")
    func smallFrameNotEnlarged() throws {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let small = CGRect(x: 2000, y: 200, width: 120, height: 80)
        let result = FrameSanitizer.clamped(small, into: visible)
        #expect(result.width == 120)
        #expect(result.height == 80)
        #expect(result.maxX <= visible.maxX - FrameSanitizer.margin + 0.001)
    }

    @Test("记录的外接屏被拔掉：分区回收至主屏并保持可见")
    func missingScreenRecoversToPrimary() throws {
        // 现在只有主屏。
        let screens = [screen(id: 1, name: "主显示器", x: 0, y: 0, width: 1920, height: 1080)]
        // 分区原本在外接屏 2 上（那里有负 y 或超大坐标）。
        let frame = CGRect(x: 3000, y: -800, width: 420, height: 300)

        let result = FrameSanitizer.restoreZone(frame: frame, screenID: "2", screens: screens)
        #expect(result.screenIndex == 0)
        let visible = screens[0].visibleFrame
        #expect(result.frame.maxX <= visible.maxX - FrameSanitizer.margin + 0.001)
        #expect(result.frame.minX >= visible.minX + FrameSanitizer.margin - 0.001)
        #expect(result.frame.minY >= visible.minY + FrameSanitizer.margin - 0.001)
        // 记录屏 ID 被回写为主屏
        #expect(screens[result.screenIndex].displayID == 1)
    }

    @Test("屏幕 ID 记录为空时回到主屏")
    func emptyScreenIDFallsBackToPrimary() throws {
        let screens = twoScreens()
        let frame = CGRect(x: 100, y: 100, width: 420, height: 300)
        let result = FrameSanitizer.restoreZone(frame: frame, screenID: nil, screens: screens)
        #expect(result.screenIndex == 0)
        #expect(result.frame == frame)
    }

    @Test("极小可见区域（退化几何）不产生越界结果")
    func degenerateVisibleAreaStillInside() throws {
        let tiny = CGRect(x: 0, y: 0, width: 30, height: 30)
        let frame = CGRect(x: 1000, y: 1000, width: 400, height: 300)
        let result = FrameSanitizer.clamped(frame, into: tiny)
        #expect(result.maxX <= tiny.maxX + 0.001)
        #expect(result.maxY <= tiny.maxY + 0.001)
        #expect(result.width > 0)
        #expect(result.height > 0)
    }
}
