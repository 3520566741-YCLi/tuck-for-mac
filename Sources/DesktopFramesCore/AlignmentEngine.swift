import CoreGraphics
import Foundation

/// 一条对齐引导虚线（画图软件式：边/中心对齐提示）。
/// - `isVertical == true`: 竖直虚线,position 为 x 坐标;
/// - `isVertical == false`: 水平虚线,position 为 y 坐标。
public struct GuideLine: Equatable, Sendable {
    public let isVertical: Bool
    public let position: CGFloat

    public init(isVertical: Bool, position: CGFloat) {
        self.isVertical = isVertical
        self.position = position
    }
}

/// 对齐结果：吸附后的矩形 + 命中提示线（坐标均为 AppKit 屏幕坐标,原点左下,y 向上）。
public struct AlignmentResult: Equatable, Sendable {
    public var rect: CGRect
    public var guides: [GuideLine]

    public init(rect: CGRect, guides: [GuideLine]) {
        self.rect = rect
        self.guides = guides
    }
}

/// 矩形对齐吸附引擎（无状态纯计算,便于单测）。
///
/// 把候选矩形的 6 个锚点(左/中/右 × 上/中/下…即左、水平中心、右 与 上、垂直中心、下)
/// 与其它矩形的锚点比较:任一方向距离 ≤ threshold 时吸附并给出该坐标的虚线。
/// - 每轴只吸附到“最近”的一个锚点,保证拖动手感稳定;
/// - 自身不在 `others` 中;`others` 已由调用方按同屏过滤。
public enum AlignmentEngine {
    public static let defaultThreshold: CGFloat = 6

    public static func propose(
        rect: CGRect,
        among others: [CGRect],
        threshold: CGFloat = defaultThreshold
    ) -> AlignmentResult {
        var guides: [GuideLine] = []
        var xDelta: CGFloat = 0
        var yDelta: CGFloat = 0

        // X 轴：候选左/中/右 vs 其它左/中/右
        if let hit = bestAlignment(
            myAnchors: [rect.minX, rect.midX, rect.maxX],
            others: others.map { [$0.minX, $0.midX, $0.maxX] },
            threshold: threshold
        ) {
            xDelta = hit.delta
            guides.append(GuideLine(isVertical: true, position: hit.anchor))
        }
        // Y 轴：候选下/中/上 vs 其它下/中/上
        if let hit = bestAlignment(
            myAnchors: [rect.minY, rect.midY, rect.maxY],
            others: others.map { [$0.minY, $0.midY, $0.maxY] },
            threshold: threshold
        ) {
            yDelta = hit.delta
            guides.append(GuideLine(isVertical: false, position: hit.anchor))
        }

        var snapped = rect
        snapped.origin.x += xDelta
        snapped.origin.y += yDelta
        return AlignmentResult(rect: snapped, guides: guides)
    }

    /// 在给定轴上从所有 (我锚点, 它锚点) 配对里挑 |差值| 最小的,并换算成“我要移动的位移”。
    /// 返回：移动位移 delta(加到我的原点上即可对齐到它锚点)与对齐后坐标 anchor。
    private static func bestAlignment(
        myAnchors: [CGFloat],
        others: [[CGFloat]],
        threshold: CGFloat
    ) -> (delta: CGFloat, anchor: CGFloat)? {
        var best: (delta: CGFloat, anchor: CGFloat)?
        for mine in myAnchors {
            for group in others {
                for theirs in group {
                    let d = theirs - mine
                    if abs(d) <= threshold {
                        if best == nil || abs(d) < abs(best!.delta) {
                            best = (d, theirs)
                        }
                    }
                }
            }
        }
        return best
    }
}
