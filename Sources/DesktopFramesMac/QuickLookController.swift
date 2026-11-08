import AppKit
import QuickLookUI

/// 简易 Quick Look 桥：在分区窗口中按空格 / 右键菜单触发系统快速查看面板。
/// 注意：面板需要当前应用持有 dataSource/delegate 引用，故由 ZoneWindowManager 保有一份。
/// QuickLookUI 协议未标注 @MainActor，因此协议方法保持非隔离；面板交互必须在主线程，
/// 故 toggle() 单独标 @MainActor（实际也总在主线程被调用）。
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let items: [URL]

    init(items: [URL]) {
        self.items = items
        super.init()
    }

    @MainActor
    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        items[index] as NSURL
    }
}
