import AppKit
import SwiftUI

/// 分区里每个图标的“访达式”交互层（盖在 SwiftUI 图标上面的透明 AppKit 视图）。
///
/// 为什么用 AppKit：SwiftUI 的单击 / 双击手势互相抢、`.onDrag` 只给出“复制”操作，
/// 导致双击打不开、拖到访达里变成复制。这里直接用系统的鼠标事件和拖放会话，行为和访达一致：
/// - 按下即选中；⌘ 点击加选 / 取消，⇧ 点击连选；双击打开（文件夹在访达打开）；
/// - 拖出去时同时允许“移动 / 复制 / 替身”，由目的地按访达规则决定（同盘默认移动，⌥ 复制，⌘⌥ 替身）；
/// - 文件夹图标本身也是放置目标：把东西拖到它上面就放进这个文件夹；拖到应用图标上 = 用它打开；
/// - 在同一个分区里拖动 = 调整位置（像手机桌面：别的图标滑开让位，松手按新顺序保存）；
///   拖到文件夹图标正中间停一下 = 放进这个文件夹；
/// - 右键菜单。
struct FinderItemInteraction: NSViewRepresentable {
    struct Callbacks {
        /// 鼠标按下（选中逻辑）。
        var press: (NSEvent.ModifierFlags) -> Void
        /// 单击松开且没拖动（普通点击在多选里时收窄为只选这一个，和访达一样）。
        var clickUp: (NSEvent.ModifierFlags) -> Void
        var doubleClick: () -> Void
        /// 开始拖动时要带走的文件（点在已选中的项目上 = 带走整组选中项）。
        var dragURLs: () -> [URL]
        var dragWillBegin: ([URL]) -> Void
        var menu: () -> NSMenu?
        /// 拖动悬停在这个图标上：给出拖来的文件、拖放掩码、指针在图标“正中间”已停留的秒数
        /// （nil = 不在正中间），返回要显示的操作（空 = 不接受）。
        var dragOver: ([URL], NSDragOperation, TimeInterval?) -> NSDragOperation
        var performDrop: ([URL], NSDragOperation) -> Bool
        /// 拖动离开这个图标。
        var dragExited: () -> Void
        /// 从这个图标发起的拖动结束了（不论放在哪里、有没有取消）。
        var dragEnded: () -> Void
        /// 拖动中指针移动（屏幕坐标）：用来判断是否已经拖出了玻璃框。
        var dragMoved: (NSPoint) -> Void
    }

    /// 图标“正中间”的范围（相对本视图，0–1，原点在左下角）：停在这里一会儿 = 放进文件夹。
    let centerRegion: CGRect
    let image: NSImage
    let callbacks: Callbacks

    func makeNSView(context: Context) -> FinderItemNSView {
        let view = FinderItemNSView()
        view.registerForDraggedTypes([.fileURL])
        view.update(centerRegion: centerRegion, image: image, callbacks: callbacks)
        return view
    }

    func updateNSView(_ nsView: FinderItemNSView, context: Context) {
        nsView.update(centerRegion: centerRegion, image: image, callbacks: callbacks)
    }
}

final class FinderItemNSView: NSView, NSDraggingSource {
    private var callbacks: FinderItemInteraction.Callbacks?
    private var image: NSImage?
    private var mouseDownEvent: NSEvent?
    private var didDrag = false
    private var centerRegion = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    /// 指针进入“正中间”的时刻（离开正中间就清空）。
    private var centerSince: Date?

    func update(centerRegion: CGRect, image: NSImage, callbacks: FinderItemInteraction.Callbacks) {
        self.callbacks = callbacks
        self.image = image
        self.centerRegion = centerRegion
    }

    // 拖动时指针停着不动也要持续收到 draggingUpdated（计算“停留多久”）
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    // 桌面浮窗平时不在前台：第一下点击就要生效；按住图标不能拖动整个窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        mouseDownEvent = event
        didDrag = false
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.clickCount >= 2 {
            callbacks?.doubleClick()
            mouseDownEvent = nil
            return
        }
        callbacks?.press(flags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !didDrag, let callbacks else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) >= 4 else { return }
        didDrag = true
        let urls = callbacks.dragURLs()
        guard !urls.isEmpty else { return }
        callbacks.dragWillBegin(urls)
        let icon = image ?? NSWorkspace.shared.icon(forFile: urls[0].path)
        let side = min(bounds.width, bounds.height, 56)
        let origin = convert(down.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let img = index == 0 ? icon : NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(
                NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                contents: img
            )
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
        mouseDownEvent = nil
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil, !didDrag {
            callbacks?.clickUp(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        mouseDownEvent = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        guard let menu = callbacks?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // ⌃ 点击 = 右键（和访达一样）
    override func menu(for event: NSEvent) -> NSMenu? { callbacks?.menu() }

    // MARK: 拖出（NSDraggingSource）

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 同时提供移动 / 复制 / 替身，由目的地（访达、桌面、别的文件夹）按自己的规则挑：
        // 同一块盘默认移动，跨盘默认复制，⌥ 复制，⌘⌥ 做替身——和从访达拖出去完全一样。
        [.move, .copy, .link, .generic]
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        callbacks?.dragMoved(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        callbacks?.dragEnded()
    }

    // MARK: 放进来（文件夹 / 应用图标是放置目标）

    /// 同一次拖动里拖的是哪些文件不会变：只读一次剪贴板（每帧都读会卡）。
    private var cachedURLs: (sequence: Int, urls: [URL])?

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        if let cached = cachedURLs, cached.sequence == info.draggingSequenceNumber { return cached.urls }
        let urls = readURLs(info)
        cachedURLs = (info.draggingSequenceNumber, urls)
        return urls
    }

    private func readURLs(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return objects ?? []
    }

    private func evaluate(_ info: NSDraggingInfo) -> NSDragOperation {
        let urls = draggedURLs(info)
        guard !urls.isEmpty, let callbacks, bounds.width > 0, bounds.height > 0 else { return [] }
        let p = convert(info.draggingLocation, from: nil)
        let unit = CGPoint(x: p.x / bounds.width, y: isFlipped ? 1 - p.y / bounds.height : p.y / bounds.height)
        var dwell: TimeInterval?
        if centerRegion.contains(unit) {
            let since = centerSince ?? Date()
            centerSince = since
            dwell = Date().timeIntervalSince(since)
        } else {
            centerSince = nil
        }
        return callbacks.dragOver(urls, info.draggingSourceOperationMask, dwell)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        centerSince = nil
        return evaluate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        centerSince = nil
        callbacks?.dragExited()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        centerSince = nil
        callbacks?.dragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        centerSince = nil
        let urls = draggedURLs(sender)
        guard !urls.isEmpty, let callbacks else { return false }
        return callbacks.performDrop(urls, sender.draggingSourceOperationMask)
    }
}

/// 用闭包当动作的菜单项（右键菜单用）。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, keyEquivalent: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
