import CoreGraphics
import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("对齐吸附引擎")
struct AlignmentEngineTests {

    @Test("右边缘在阈值内：吸附并给出竖直虚线")
    func snapRightEdge() {
        // 左卡右缘 x=200；右卡左缘 x=205 → 差 5 ≤ 6
        let moving = CGRect(x: 100, y: 100, width: 100, height: 80) // 右缘 200
        let fixed = CGRect(x: 205, y: 50, width: 120, height: 60)  // 左缘 205
        let result = AlignmentEngine.propose(rect: moving, among: [fixed])
        #expect(result.rect.minX == 105) // 右缘对齐到 205
        #expect(result.rect.maxX == 205)
        #expect(result.guides.contains(GuideLine(isVertical: true, position: 205)))
    }

    @Test("超出阈值不吸附、无虚线")
    func noSnapBeyondThreshold() {
        let moving = CGRect(x: 100, y: 100, width: 100, height: 80)
        let fixed = CGRect(x: 208, y: 50, width: 120, height: 60) // 差 8 > 6
        let result = AlignmentEngine.propose(rect: moving, among: [fixed])
        #expect(result.rect == moving)
        #expect(result.guides.isEmpty)
    }

    @Test("多候选时吸附最近的那个")
    func snapsToNearest() {
        let moving = CGRect(x: 100, y: 100, width: 100, height: 80) // 右缘 200
        let a = CGRect(x: 202, y: 0, width: 20, height: 20)  // 左缘 202（差 2）
        let b = CGRect(x: 214, y: 0, width: 20, height: 20)  // 左缘 214（差 14 → 淘汰）
        let result = AlignmentEngine.propose(rect: moving, among: [a, b])
        #expect(result.rect.maxX == 202)
        #expect(result.rect.minX == 102)
        #expect(result.guides == [GuideLine(isVertical: true, position: 202)])
    }

    @Test("底边/垂直中心对齐给出水平虚线")
    func snapBottomAndVerticalCenter() {
        let moving = CGRect(x: 0, y: 0, width: 100, height: 100) // 顶 100
        let fixed = CGRect(x: 500, y: 96, width: 40, height: 40) // 顶 136,中心 116,底 96
        let result = AlignmentEngine.propose(rect: moving, among: [fixed])
        // 最近的是 moving.maxY(100) vs fixed.minY(96) 差 4 → 上移？移动 -4 使顶对齐到底 96
        #expect(result.rect.maxY == 96)
        #expect(result.rect.minY == -4)
        #expect(result.guides.contains(GuideLine(isVertical: false, position: 96)))
    }

    @Test("已精确对齐时保持原位但给出虚线")
    func alreadyAlignedShowsGuide() {
        let moving = CGRect(x: 100, y: 100, width: 100, height: 80)
        let fixed = CGRect(x: 200, y: 300, width: 60, height: 40) // 左缘 200 = moving 右缘
        let result = AlignmentEngine.propose(rect: moving, among: [fixed])
        #expect(result.rect == moving)
        #expect(result.guides.contains(GuideLine(isVertical: true, position: 200)))
    }
}
