import AppKit
import DesktopFramesCore

/// 覆盖在某块屏幕上的对齐虚线层（穿透鼠标、不接收事件）。
final class AlignmentOverlayView: NSView {
    /// 当前要画的引导线（AppKit 屏幕坐标,原点左下,y 向上,与窗口 bounds 一致）。
    var lines: [GuideLine] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !lines.isEmpty else { return }
        let color = NSColor.controlAccentColor.withAlphaComponent(0.9)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.setLineDash([4, 4], count: 2, phase: 0)
        for line in lines {
            if line.isVertical {
                path.move(to: NSPoint(x: line.position, y: 0))
                path.line(to: NSPoint(x: line.position, y: bounds.height))
            } else {
                path.move(to: NSPoint(x: 0, y: line.position))
                path.line(to: NSPoint(x: bounds.width, y: line.position))
            }
        }
        path.stroke()
    }
}

/// 全屏对齐虚线窗口：浮动于分区窗口之上、忽略鼠标。
final class AlignmentOverlayWindow: NSWindow {
    let guideView = AlignmentOverlayView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false // 由管理器持有 / 释放，避免 close 时重复释放
        contentView = guideView
    }

    func showLines(_ lines: [GuideLine]) {
        guideView.lines = lines
        if lines.isEmpty {
            orderOut(nil)
        } else if !isVisible {
            orderFrontRegardless()
        }
    }
}
