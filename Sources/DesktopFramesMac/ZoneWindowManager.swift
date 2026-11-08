import AppKit
import Combine
import DesktopFramesCore
import QuartzCore
import SwiftUI

/// 分区窗口管理：为每个 Zone 创建无标题、可移动 / 缩放的桌面浮层窗口，
/// 响应窗口移动 / 缩放并把几何写回 AppModel，处理启动恢复与屏幕变更回收。
@MainActor
final class ZoneWindowManager: NSObject, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    let store: ZoneStore
    let model: AppModel
    private var windows: [UUID: NSWindow] = [:]
    private let fileService = FileOperationService()
    /// 正在进行的文件移动（后台执行，分区里显示进度、可取消）。
    let transfers = TransferCenter()
    /// 移动进行中用户要退出：等它取消 / 完成后再退出。
    private var quitWhenTransferEnds = false
    private var quickLookController: QuickLookController?
    /// FSEvents 监听条目所在文件夹，有变化才清理失效入口（替代旧的定时轮询）。
    private var folderWatcher: FolderWatcher?
    private var modelObservation: AnyCancellable?
    /// 桌面原图标隐藏：对账器与“Tuck 隐藏过哪些文件”的记录（单独文件，不进布局 / 备份）。
    private var desktopHider: DesktopHider?
    private var hiddenRegistry: HiddenRegistry?
    /// 崩溃 / 被强杀时恢复桌面原图标的看门狗子进程。
    private let watchdog = Watchdog()
    weak var hideOnDesktopMenuItem: NSMenuItem?
    /// “偷看”模式：分区临时浮到所有窗口最上层。
    private(set) var isPeeking = false
    weak var peekMenuItem: NSMenuItem?
    /// 对齐辅助线覆盖窗口（按屏）。
    private var alignmentOverlays: [UInt32: AlignmentOverlayWindow] = [:]
    /// 程序化改帧时置位,避免被误判为用户拖动（也跳过重复持久化）。
    private var programmaticFrameChange = false
    /// 正在做收起/展开等程序化动画的窗口（动画期间不当作“用户拖动”处理）。
    private var animatedMoveWindows = Set<NSWindow>()
    /// 每个分区的收起 / 展开“代号”：快速连点时，旧动画的延迟回调发现代号变了就什么都不做。
    private var morphGeneration: [UUID: Int] = [:]
    /// 吸附后 setFrame 会再次回调 windowDidMove,用此标记避免递归处理。
    private var isApplyingSnap = false
    /// 拖动过程中已展示引导线,等待鼠标抬起清除。
    private var mouseUpMonitor: Any?
    /// 菜单栏中的撤销项（启用态 / 文案在 validateMenuItem 中维护）。
    weak var undoMenuItem: NSMenuItem?
    /// 菜单栏中的“退出时自动归位”开关项。
    weak var restoreOnQuitMenuItem: NSMenuItem?

    init(store: ZoneStore) {
        self.store = store
        self.model = AppModel(store: store, screens: NSScreen.dshAll)
        super.init()
        // 测试用：DESKTOPFRAMES_DESKTOP_DIR 指向一个测试目录当“桌面”（不碰真实桌面）
        let desktopOverride = ProcessInfo.processInfo.environment["DESKTOPFRAMES_DESKTOP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let desktop = desktopOverride ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            desktopHider = DesktopHider(desktop: desktop)
            hiddenRegistry = HiddenRegistry(
                file: store.layoutFile.deletingLastPathComponent().appendingPathComponent("hidden-by-tuck.json")
            )
        }
        startStaleEntryWatching()
        if let registry = hiddenRegistry, let desktop = desktopHider?.desktop {
            try? registry.writeList() // 清单与记录保持一致（旧版本只有 JSON）
            watchdog.start(listFile: registry.listFile, desktop: desktop)
        }
    }

    // MARK: - 在桌面上隐藏已收纳的原图标

    static let hideOnDesktopKey = "HideCollectedDesktopIcons"

    /// 默认开启。
    var isHideOnDesktopEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.hideOnDesktopKey) as? Bool ?? true
    }

    @objc func toggleHideOnDesktop(_ sender: Any?) {
        UserDefaults.standard.set(!isHideOnDesktopEnabled, forKey: Self.hideOnDesktopKey)
        hideOnDesktopMenuItem?.state = isHideOnDesktopEnabled ? .on : .off
        reconcileDesktopHiding()
    }

    /// 让“桌面上被隐藏的原图标”与分区内容一致：
    /// 普通 / 应用分区里的桌面直属项目 → 隐藏；不再在分区里 / 功能关闭 → 只恢复 Tuck 自己隐藏的。
    /// 文件夹分区不参与（那里的文件本来就被真实移走了）。
    func reconcileDesktopHiding() {
        guard let hider = desktopHider, let registry = hiddenRegistry else { return }
        var wanted = Set<String>()
        if isHideOnDesktopEnabled {
            for zone in model.document.zones where zone.kind != .folder {
                for item in zone.items where item.url.isFileURL {
                    wanted.insert(DesktopHider.canonicalItemPath(item.url)) // 大小写不同的两条入口算同一个文件
                }
            }
        }
        let result = hider.reconcile(wanted: wanted, tracked: registry.paths) { registry.update($0) } relocate: { registry.locate($0) } isOriginal: { registry.isOriginal($0) }
        registry.update(result)
    }

    /// 从分区里把项目拖出去之前：先恢复显示，避免带着隐藏标记被移到别处“消失”。
    func prepareDragOut(_ url: URL) {
        prepareDragOut([url])
    }

    /// 从分区里开始拖图标：先记下来，等指针真的离开所有玻璃框时才恢复桌面原图标
    /// （之前一开始拖桌面上就冒出原图标，看起来像“先跑到桌面”）。
    private var pendingDragOutURLs: [URL] = []
    private var lastTopmostCheck: TimeInterval = 0

    func beginItemDrag(_ urls: [URL]) {
        pendingDragOutURLs = urls
        dropOpMemo = nil
    }

    /// 拖动中：指针一出玻璃框就恢复原图标显示，这样放到桌面 / 访达时文件不会带着隐藏标记。
    func itemDragMoved(to screenPoint: NSPoint) {
        guard !pendingDragOutURLs.isEmpty else { return }
        // 先用窗口位置粗判（不用问窗口服务器）：不在任何玻璃框范围里 = 肯定出框了。
        let inZoneFrame = windows.values.contains { $0.isVisible && $0.frame.contains(screenPoint) }
        if inZoneFrame {
            // 在玻璃框范围里：再看指针下面“最上层”的窗口是不是玻璃框（访达窗口可能叠在上面，那算出框）。
            // 这一步要问窗口服务器，每次移动都问会拖慢拖动，限制为每 50 毫秒最多一次。
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastTopmostCheck >= 0.05 else { return }
            lastTopmostCheck = now
            let topmost = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            let insideZone = windows.values.contains { $0.isVisible && $0.windowNumber == topmost }
            guard !insideZone else { return }
        }
        let urls = pendingDragOutURLs
        pendingDragOutURLs = []
        prepareDragOut(urls)
    }

    /// 拖动结束（放在框里 / 取消）：没出过框就什么都不用恢复。
    func endItemDrag() {
        pendingDragOutURLs = []
        dropOpMemo = nil
    }

    /// 同上，一次处理多个（多选拖动 / 拖到分区里的文件夹上）。
    func prepareDragOut(_ urls: [URL]) {
        guard releaseHidden(urls) else { return }
        reconcileAfterDragEnds()
    }

    /// 把这些文件里被 Tuck 隐藏的先恢复显示（移动 / 复制前调用，免得带着隐藏标记过去）。
    /// 返回是否真的恢复了任何一个。之后的对账会把仍在分区里、仍在桌面上的重新隐藏。
    @discardableResult
    private func releaseHidden(_ urls: [URL]) -> Bool {
        guard let registry = hiddenRegistry, let hider = desktopHider else { return false }
        let paths = Set(urls.map { DesktopHider.canonicalItemPath($0) })
        guard !paths.isDisjoint(with: registry.paths) else { return false }
        let remaining = registry.paths.subtracting(paths)
        let result = hider.reconcile(wanted: remaining, tracked: registry.paths) { registry.update($0) } relocate: { registry.locate($0) } isOriginal: { registry.isOriginal($0) }
        registry.update(result)
        return true
    }

    /// 拖动结束（鼠标松开）后再对账一次：拖到别处的已不在桌面，不会再隐藏；
    /// 取消拖放的仍在分区里、仍在桌面上，就重新隐藏。
    /// 每次拖动一个“代号”，旧拖动留下的回调不会影响新拖动；监听用完即移除。
    private var dragEndMonitors: [Any] = []
    private var dragGeneration = 0

    private func reconcileAfterDragEnds() {
        removeDragEndMonitors()
        dragGeneration += 1
        let generation = dragGeneration
        let finish: () -> Void = { [weak self] in
            guard let self, self.dragGeneration == generation, !self.dragEndMonitors.isEmpty else { return }
            self.removeDragEndMonitors()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.reconcileDesktopHiding()
            }
        }
        // 拖到其它 App / 桌面时松开是全局事件，拖回本 App 窗口内松开是本地事件，两个都挂。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
        }) {
            dragEndMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
            return event
        }) {
            dragEndMonitors.append(local)
        }
        // 拖拽循环可能吞掉松开事件：每秒看一次鼠标键，松开了就结束（只在拖动期间轮询，最多 2 分钟）。
        pollDragEnd(generation: generation, remaining: 120, finish: finish)
    }

    private func pollDragEnd(generation: Int, remaining: Int, finish: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.dragGeneration == generation, !self.dragEndMonitors.isEmpty else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 || remaining <= 0 {
                finish()
            } else {
                self.pollDragEnd(generation: generation, remaining: remaining - 1, finish: finish)
            }
        }
    }

    private func removeDragEndMonitors() {
        for monitor in dragEndMonitors { NSEvent.removeMonitor(monitor) }
        dragEndMonitors.removeAll()
    }

    /// 退出时把 Tuck 隐藏的原图标全部恢复显示（Tuck 不在运行时桌面保持原样）。
    func restoreDesktopIcons() {
        defer { watchdog.stopCleanly() } // 已经自己恢复完了，告诉看门狗不用再做
        guard let hider = desktopHider, let registry = hiddenRegistry else { return }
        let result = hider.restoreAll(tracked: registry.paths) { registry.update($0) } relocate: { registry.locate($0) } isOriginal: { registry.isOriginal($0) }
        registry.update(result)
    }

    /// 失效条目清理：条目指向的文件被拖出/移动/删除（父目录仍存在）时自动移除入口。
    /// 只在被监听的文件夹真的发生变化时才检查一次；布局变化后（防抖 0.5 秒）更新监听集合。
    private func startStaleEntryWatching() {
        let watcher = FolderWatcher { [weak self] in
            self?.model.purgeMissingEntries()
            self?.refreshWatchedFolders()
            self?.reconcileDesktopHiding()
        }
        folderWatcher = watcher
        modelObservation = model.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWatchedFolders()
                    self?.reconcileDesktopHiding()
                }
            }
        refreshWatchedFolders()
        cleanUpPartialCopies()
        model.purgeMissingEntries() // 启动时补一次（离线期间的变化）
        reconcileDesktopHiding()    // 启动对账（含上次崩溃后的恢复）
    }

    /// 上次跨盘移动途中崩溃留下的未完成临时副本（Tuck 自己创建、隐藏名字），启动时清掉。
    /// 只认文件夹分区关联文件夹里、以固定前缀开头的项目；源文件那边从未被动过。
    private func cleanUpPartialCopies() {
        PartialJournal.file = store.layoutFile.deletingLastPathComponent().appendingPathComponent("partial-copies.json")
        PartialJournal.cleanUp() // 按登记清理（任意目标文件夹）
        let fm = FileManager.default
        for zone in model.document.zones where zone.kind == .folder {
            guard let folder = zone.backingFolderURL,
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasPrefix(FileOperationService.partialPrefix) {
                FileOperationService.removePartial(folder.appendingPathComponent(name))
            }
        }
    }

    /// 需要监听的文件夹 = 各条目的父目录 + 文件分区的关联文件夹（只监听存在的目录）。
    private func refreshWatchedFolders() {
        let fm = FileManager.default
        var paths = Set<String>()
        for zone in model.document.zones {
            if let folder = zone.backingFolderURL { paths.insert(folder.standardizedFileURL.path) }
            for item in zone.items {
                paths.insert(item.url.deletingLastPathComponent().standardizedFileURL.path)
            }
        }
        let existing = paths.filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        folderWatcher?.watch(paths: existing)
    }

    /// 手动清理失效入口（分区菜单“清理失效入口…”），返回清理条数。
    @discardableResult
    func purgeNow() -> Int {
        model.purgeMissingEntries()
    }

    // MARK: - 生命周期

    func persistNow() {
        model.persistNow()
    }

    /// 退出前停止文件监听。
    func shutdown() {
        removeDragEndMonitors()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        folderWatcher?.stop()
        modelObservation = nil
    }

    // MARK: - 窗口层级 / 偷看

    /// 常态层级：桌面图标之上、所有普通窗口之下（不挡干活）。
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    /// 当前应使用的窗口层级。
    private var currentLevel: NSWindow.Level { isPeeking ? .floating : Self.desktopLevel }

    /// 切换“偷看”：分区临时浮到最上层，再按一次回到桌面层。
    @objc func togglePeek(_ sender: Any?) {
        setPeeking(!isPeeking)
    }

    func setPeeking(_ peeking: Bool) {
        isPeeking = peeking
        peekMenuItem?.state = peeking ? .on : .off
        for window in windows.values {
            window.level = currentLevel
            if peeking { window.orderFrontRegardless() }
        }
    }

    /// 同步窗口与文档：新建缺失的分区窗口，关闭已被删除的分区窗口。启动恢复入口。
    func syncAllWindows() {
        let zones = model.document.zones
        var seen = Set<UUID>()
        for zone in zones {
            seen.insert(zone.id)
            guard windows[zone.id] == nil else { continue }
            createWindow(for: zone)
        }
        for (id, window) in windows where !seen.contains(id) {
            window.delegate = nil
            window.close()
            windows.removeValue(forKey: id)
        }
    }

    /// 屏幕布局变化（外接屏拔掉 / 分辨率变化）：把所有分区夹取回可见区域。
    func reflowAllWindows() {
        let screens = NSScreen.dshAll
        guard !screens.isEmpty else { return }
        hideAlignmentGuides()
        programmaticFrameChange = true
        defer { programmaticFrameChange = false }
        for zone in model.document.zones {
            guard windows[zone.id] != nil else { continue }
            let result = FrameSanitizer.restoreZone(
                frame: FrameSanitizer.cgRect(from: zone.frame),
                screenID: zone.screenID,
                screens: screens
            )
            var target = result.frame
            if zone.appearance.collapsed {
                // 收起状态只放一条薄条（顶边沿用夹取后的位置），不要把透明的大窗口铺出来
                target.origin.y = target.maxY - Self.collapsedWindowHeight
                target.size.height = Self.collapsedWindowHeight
            }
            windows[zone.id]?.setFrame(target, display: true)
            let chosenID = screens[result.screenIndex].displayID
            if FrameSanitizer.parseScreenID(zone.screenID) != chosenID {
                model.updateScreenID(zoneID: zone.id, screenID: "\(chosenID)")
            }
        }
    }

    // MARK: - 新建分区（菜单栏动作）

    @objc func newFolderZone(_ sender: Any?) { createZoneFlow(kind: .folder) }
    @objc func newVirtualZone(_ sender: Any?) { createZoneFlow(kind: .virtual) }
    @objc func newAppZone(_ sender: Any?) { createZoneFlow(kind: .app) }

    private func createZoneFlow(kind: ZoneKind) {
        var backingFolderPath: String?

        if kind == .folder {
            guard let url = promptForBackingFolder() else { return }
            backingFolderPath = url.path
        }

        let defaultName = defaultName(for: kind)
        guard let name = promptForName(
            title: "新建\(kind.displayName)",
            message: backingFolderPath == nil
                ? "输入分区名称。"
                : "关联文件夹：\(backingFolderPath ?? "")",
            defaultText: defaultName
        ), !name.isEmpty else { return }

        let placement = placementForNewZone()
        model.createZone(
            kind: kind,
            name: name,
            frame: placement.frame,
            screenID: placement.screenID,
            backingFolderPath: backingFolderPath
        )
        syncAllWindows()
    }

    // MARK: - 分区操作（窗口内动作）

    func promptRename(zoneID: UUID) {
        guard let zone = model.zone(id: zoneID) else { return }
        guard let name = promptForName(title: "重命名分区", message: "输入新名称。", defaultText: zone.name),
              !name.isEmpty, name != zone.name else { return }
        model.renameZone(id: zoneID, name: name)
    }

    func promptDelete(zoneID: UUID) {
        guard let zone = model.zone(id: zoneID) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除分区“\(zone.name)”？"
        alert.informativeText = "仅移除分区及其入口，不会删除任何文件或文件夹。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteZone(id: zoneID)
        windows[zoneID]?.delegate = nil
        windows[zoneID]?.close()
        windows.removeValue(forKey: zoneID)
    }

    // MARK: - 拖放入口（三类分区各自的文件行为）

    /// 统一入口：Finder 拖入一组 URL。
    func drop(urls: [URL], into zoneID: UUID) {
        guard let zone = model.zone(id: zoneID), !urls.isEmpty else { return }
        switch zone.kind {
        case .virtual:
            addEntries(urls: urls, to: zone, moved: false)
        case .app:
            let apps = urls.filter { FileTypeInspector.kind(of: $0) == .application }
            if apps.count != urls.count {
                inform(title: "应用分区", text: "只接受应用（.app）入口，已忽略 \(urls.count - apps.count) 个非应用项目。")
            }
            addEntries(urls: apps, to: zone, moved: false)
        case .folder:
            // 已经在关联文件夹里的项目（从本分区拖出又拖回 / 两个分区共用一个文件夹）不处理。
            let outside = urls.filter { url in
                guard let folder = zone.backingFolderURL else { return true }
                return FileOperationService.canonicalPath(url.deletingLastPathComponent())
                    != FileOperationService.canonicalPath(folder)
            }
            // 来自普通 / 应用分区的项目（从分区里拖过来）绝不真实移动：那些分区承诺“不动原文件”。
            let entryPaths = Set(model.document.zones.filter { $0.kind != .folder }
                .flatMap { $0.items.map { $0.url.standardizedFileURL.path } })
            let movable = outside.filter { !entryPaths.contains($0.standardizedFileURL.path) }
            if movable.count < outside.count {
                inform(title: "没有移动",
                       text: "有 \(outside.count - movable.count) 个项目来自普通 / 应用分区，这类分区不移动原文件。如需移动，请从访达拖入。")
            }
            guard !movable.isEmpty else { return }
            performRealMove(urls: movable, into: zone)
        }
    }

    private func addEntries(urls: [URL], to zone: Zone, moved: Bool) {
        var added = 0
        for url in urls {
            // 用文件真实路径（系统记录的大小写）存入口，同一文件不会因大小写不同被加两次
            let real = URL(fileURLWithPath: DesktopHider.canonicalItemPath(url),
                           isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            let item = ZoneItem(url: real, kind: FileTypeInspector.kind(of: real))
            if model.addItem(item, to: zone.id) { added += 1 }
        }
        // 已在分区里的项目直接跳过、不弹框（例如把图标拖出去又放回本分区）
    }

    /// 文件分区：真实移动到关联文件夹，冲突需用户选择，成功后记录整批撤销。
    private func performRealMove(urls: [URL], into zone: Zone) {
        guard let folder = zone.backingFolderURL else {
            inform(title: "无法移动", text: "此分区没有关联文件夹。请删除后重新创建“文件分区”并选择文件夹。")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            inform(title: "无法移动", text: "分区关联的文件夹不存在：\(folder.path)\n请删除分区并重新创建，选择存在的文件夹。")
            return
        }

        // 冲突检测：目标已有同名项才弹窗（默认取消是安全路径）。
        let conflicts = urls.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.lastPathComponent).path) }
        let policy: ConflictPolicy
        if !conflicts.isEmpty {
            guard let chosen = promptConflictPolicy(conflictNames: conflicts.map(\.lastPathComponent)) else {
                return // 用户取消整批
            }
            policy = chosen
        } else {
            policy = .cancel // 无冲突时等同于“直接移动”
        }

        // 真实移动放到后台：跨盘大文件夹也不会让界面转圈；分区里显示进度，可随时取消。
        let service = fileService
        let zoneID = zone.id
        runTransfer(zoneID: zoneID, title: "正在移入 \(urls.count) 项…") { progress -> [MoveResult] in
            var results: [MoveResult] = []
            // 同一批里有重名项目（例如来自访达搜索结果）：第二个起一律“保留两者”，绝不互相替换。
            var namesInBatch = Set<String>()
            for url in urls {
                if progress.isCancelled { results.append(MoveResult(source: url, status: .cancelled)); continue }
                let name = url.lastPathComponent
                let itemPolicy: ConflictPolicy = namesInBatch.contains(name) ? .keepBoth : policy
                namesInBatch.insert(name)
                results.append(MoveResult.run(url) {
                    try service.moveDetailed(item: url, into: folder, policy: itemPolicy, progress: progress)
                })
            }
            return results
        } completion: { [weak self] results in
            guard let self else { return }
            var records: [MoveUndoRecord] = []
            for r in results {
                guard case .moved(let destination, let trashed) = r.status else { continue }
                var item = ZoneItem(
                    url: destination,
                    kind: FileTypeInspector.kind(of: destination),
                    movedFrom: r.source // 记录拖入前原位置，退出时据此“放回桌面原位置”
                )
                item.movedFileNumber = Self.fileNumber(of: destination)
                self.model.addItem(item, to: zoneID)
                records.append(MoveUndoRecord(source: r.source, destination: destination, replacedTrashURL: trashed))
            }
            if !records.isEmpty {
                self.model.setUndoBatch(records)
                self.inform(title: "已移动 \(records.count) 项", text: "可通过菜单栏“撤销上次移动”还原。")
            }
            self.reportProblems(results, verb: "移动")
        }
    }

    private func promptConflictPolicy(conflictNames: [String]) -> ConflictPolicy? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "分区文件夹中已有同名项目"
        let shown = conflictNames.prefix(5).joined(separator: "、")
        alert.informativeText = conflictNames.count > 5
            ? "\(shown) 等 \(conflictNames.count) 项与目标文件夹重名。请选择处理方式："
            : "\(shown) 与目标文件夹重名。请选择处理方式："
        // “取消”是默认按钮（回车 = 取消），替换需要明确点选；被替换的旧文件会进废纸篓。
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "保留两者")
        alert.addButton(withTitle: "替换（旧文件移到废纸篓）")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .replace
        default: return nil
        }
    }

    // MARK: - 项目操作（打开 / 访达 / 快速查看 / 移除入口）

    func openItem(_ url: URL) {
        guard url.isFileURL else { return } // 只打开本地文件
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            informMissingAndRemove(url: url)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealItem(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            informMissingAndRemove(url: url)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 文件已被移动/删除：父目录仍在则视为“失效入口”，提示后移除；父目录也没了提示不可用。
    private func informMissingAndRemove(url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.deletingLastPathComponent().path) {
            model.removeEntries(pointingTo: url)
            inform(title: "入口已失效", text: "“\(url.lastPathComponent)”已不在原位置（可能被移动或删除），已从分区移除该入口。")
        } else {
            inform(title: "无法打开", text: "“\(url.lastPathComponent)”所在的文件夹当前不可用。")
        }
    }

    // MARK: - 把项目移出分区（App 自己执行真实移动，保证“移出=移动”）

    /// 移到桌面。
    func moveItemToDesktop(item: ZoneItem, zone: Zone) {
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            inform(title: "无法移动", text: "找不到桌面目录。")
            return
        }
        moveItemOut(item: item, zone: zone, to: desktop)
    }

    /// 移到用户选择的其它文件夹。
    func moveItemToFolder(item: ZoneItem, zone: Zone) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择要把“\(item.url.lastPathComponent)”移动到的文件夹"
        panel.prompt = "移动到此"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        moveItemOut(item: item, zone: zone, to: folder)
    }

    private func moveItemOut(item: ZoneItem, zone: Zone, to folder: URL) {
        // 普通 / 应用分区只放入口，绝不移动原文件。
        guard zone.kind == .folder else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.url.path) else {
            informMissingAndRemove(url: item.url)
            return
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            inform(title: "无法移动", text: "目标文件夹不存在。")
            return
        }

        let targetName = item.url.lastPathComponent
        let conflict = fm.fileExists(atPath: folder.appendingPathComponent(targetName).path)
        let policy: ConflictPolicy
        if conflict {
            guard let chosen = promptConflictPolicy(conflictNames: [targetName]) else { return }
            policy = chosen
        } else {
            policy = .cancel
        }

        let service = fileService
        let source = item.url
        let itemID = item.id, zoneID = zone.id
        runTransfer(zoneID: zoneID, title: "正在移出“\(targetName)”…") { progress -> [MoveResult] in
            [MoveResult.run(source) { try service.moveDetailed(item: source, into: folder, policy: policy, progress: progress) }]
        } completion: { [weak self] results in
            guard let self, let r = results.first else { return }
            switch r.status {
            case .moved(let destination, let trashed):
                self.model.removeItem(id: itemID, from: zoneID)
                self.model.setUndoBatch([MoveUndoRecord(source: source, destination: destination, replacedTrashURL: trashed)])
                self.inform(title: "已移出", text: "“\(targetName)”已移动到：\(destination.path)\n可通过菜单栏“撤销上次移动”移回。")
            case .skipped:
                self.inform(title: "已取消", text: "目标文件夹已有同名项目，未执行移动。")
            default:
                self.reportProblems(results, verb: "移动")
            }
        }
    }

    /// 正在从某个分区里拖出的项目（用来区分“在本分区里调整位置”和“从外面拖进来”）。
    struct ReorderDrag: Equatable {
        let zoneID: UUID
        let itemIDs: Set<UUID>
    }
    var reorderDrag: ReorderDrag?

    // MARK: - 像访达一样：把东西拖到分区里的文件夹 / 应用图标上

    enum ItemDropOperation: Equatable {
        case move, copy, alias, openWith

        var dragOperation: NSDragOperation {
            switch self {
            case .move: return .move
            case .copy: return .copy
            case .alias: return .link
            case .openWith: return .generic
            }
        }
    }

    /// 这个项目能不能接住拖放：真正的文件夹（不含 .app 之类的“包”）和应用。
    static func acceptsDrops(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isApplicationKey])
        if values?.isApplication == true { return true }
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// 按访达的规则决定拖到 target 上会发生什么（nil = 不接受）：
    /// 应用 → 用它打开；文件夹 → 同盘默认移动、跨盘默认复制，⌥ 复制，⌘ 强制移动，⌘⌥ 做替身。
    /// 拖动时每帧都会问一次，判断要读磁盘：同样的问题直接用上一次的答案。
    private var dropOpMemo: (key: String, value: ItemDropOperation?)?

    func dropOperation(for urls: [URL], onto target: URL, mask: NSDragOperation) -> ItemDropOperation? {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = "\(target.path)|\(mask.rawValue)|\(flags.rawValue)|" + urls.map(\.path).joined(separator: "|")
        if let memo = dropOpMemo, memo.key == key { return memo.value }
        let value = computeDropOperation(for: urls, onto: target, mask: mask)
        dropOpMemo = (key, value)
        return value
    }

    private func computeDropOperation(for urls: [URL], onto target: URL, mask: NSDragOperation) -> ItemDropOperation? {
        guard !urls.isEmpty, FileManager.default.fileExists(atPath: target.path) else { return nil }
        let t = FileOperationService.canonicalPath(target)
        for url in urls {
            let c = FileOperationService.canonicalPath(url)
            if c == t || t.hasPrefix(c + "/") { return nil } // 拖到自己身上 / 拖进自己里面
        }
        if (try? target.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true {
            return .openWith
        }
        guard Self.acceptsDrops(target) else { return nil }
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let canMove = !mask.isDisjoint(with: [.move, .generic])
        let op: ItemDropOperation?
        if flags.contains(.option) && flags.contains(.command) {
            op = mask.isEmpty ? nil : .alias
        } else if flags.contains(.option) {
            op = mask.contains(.copy) ? .copy : nil
        } else if flags.contains(.command) {
            op = canMove ? .move : nil
        } else {
            let sameVolume = urls.allSatisfy { Self.sameVolume($0, target) }
            op = (sameVolume && canMove) ? .move : (mask.contains(.copy) ? .copy : (canMove ? .move : nil))
        }
        // 本来就在这个文件夹里的东西再“移”进去 = 什么都不做（访达也不接）
        if op == .move, urls.allSatisfy({ FileOperationService.canonicalPath($0.deletingLastPathComponent()) == t }) {
            return nil
        }
        return op
    }

    /// 执行拖到项目上的放置。zoneID 只用于在哪个分区显示进度条。
    @discardableResult
    func performItemDrop(urls: [URL], onto target: URL, mask: NSDragOperation, zoneID: UUID) -> Bool {
        defer { dropOpMemo = nil } // 放完文件位置变了，下次重新判断
        guard let op = dropOperation(for: urls, onto: target, mask: mask) else { return false }
        switch op {
        case .openWith:
            NSWorkspace.shared.open(urls, withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .alias:
            makeAliases(urls, in: target)
            return true
        case .move, .copy:
            // 拖放的松开要先结束，再弹冲突对话框（否则对话框会卡住拖放会话）
            DispatchQueue.main.async { [weak self] in
                self?.transferIntoFolder(urls: urls, folder: target, copy: op == .copy, zoneID: zoneID)
            }
            return true
        }
    }

    /// 移动 / 复制到某个文件夹（后台进行，分区里显示进度，可取消），和访达一样不弹“已完成”提示。
    private func transferIntoFolder(urls: [URL], folder: URL, copy: Bool, zoneID: UUID) {
        let fm = FileManager.default
        let folderPath = FileOperationService.canonicalPath(folder)
        let candidates = urls.filter { fm.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else { return }
        guard !transfers.isBusy else {
            inform(title: "请稍候", text: "上一次移动还没完成，可以在分区里看到进度或点“取消”。")
            return
        }
        // 冲突：目标里已有同名项（复制到原文件夹会自动另起名字，不算冲突）
        let conflicts = candidates.filter { url in
            let sameFolder = FileOperationService.canonicalPath(url.deletingLastPathComponent()) == folderPath
            if sameFolder { return false }
            return fm.fileExists(atPath: folder.appendingPathComponent(url.lastPathComponent).path)
        }
        var policy: ConflictPolicy = .cancel
        if !conflicts.isEmpty {
            guard let chosen = promptConflictPolicy(conflictNames: conflicts.map(\.lastPathComponent)) else { return }
            policy = chosen
        }
        // 被 Tuck 藏起来的桌面文件：先恢复显示再动，移过去 / 复制出来的都不会是隐藏的
        releaseHidden(candidates)
        let service = fileService
        let chosenPolicy = policy
        let verb = copy ? "复制" : "移动"
        runTransfer(zoneID: zoneID, title: "正在\(verb) \(candidates.count) 项到“\(folder.lastPathComponent)”…") { progress -> [MoveResult] in
            var results: [MoveResult] = []
            var namesInBatch = Set<String>()
            for url in candidates {
                if progress.isCancelled { results.append(MoveResult(source: url, status: .cancelled)); continue }
                let name = url.lastPathComponent
                let itemPolicy: ConflictPolicy = namesInBatch.contains(name) ? .keepBoth : chosenPolicy
                namesInBatch.insert(name)
                results.append(MoveResult.run(url) {
                    try copy
                        ? service.copyDetailed(item: url, into: folder, policy: itemPolicy, progress: progress)
                        : service.moveDetailed(item: url, into: folder, policy: itemPolicy, progress: progress)
                })
            }
            return results
        } completion: { [weak self] results in
            guard let self else { return }
            if !copy {
                let records = results.compactMap { r -> MoveUndoRecord? in
                    guard case .moved(let destination, let trashed) = r.status else { return nil }
                    return MoveUndoRecord(source: r.source, destination: destination, replacedTrashURL: trashed)
                }
                if !records.isEmpty { self.model.setUndoBatch(records) } // 菜单栏“撤销上次移动”可还原
                // 已经不在原处的入口立即去掉（不等文件夹监听），和访达里文件“走了”一样
                self.model.purgeMissingEntries()
            }
            self.reconcileDesktopHiding()
            self.reportProblems(results, verb: verb)
        }
    }

    /// ⌘⌥ 拖放：在目标文件夹里做替身（和访达的“制作替身”同一种文件）。
    private func makeAliases(_ urls: [URL], in folder: URL) {
        var failures: [String] = []
        for url in urls {
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                let base = url.lastPathComponent + " 的替身"
                var dest = folder.appendingPathComponent(base)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = folder.appendingPathComponent("\(base) \(n)")
                    n += 1
                }
                try URL.writeBookmarkData(data, to: dest)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            inform(title: "无法制作替身", text: failures.joined(separator: "\n"))
        }
    }

    /// 打开多个（双击 / ⌘O 作用于整组选中项）。
    func openItems(_ urls: [URL]) {
        for url in urls { openItem(url) }
    }

    func quickLookItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = QuickLookController(items: urls)
        quickLookController = controller
        controller.toggle()
    }

    // MARK: - 键盘（分区窗口在前时：空格快速查看、⌘O 打开、⌘A 全选、⌘C 拷贝、Esc 取消选择）

    private var keyHandlers: [UUID: (NSEvent) -> Bool] = [:]
    private var keyMonitor: Any?

    func setKeyHandler(zoneID: UUID, _ handler: ((NSEvent) -> Bool)?) {
        keyHandlers[zoneID] = handler
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // 本地监听总在主线程回调；NSEvent 不是 Sendable，装进盒子只在主线程内使用。
                let box = MainThreadEventBox(event: event)
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self,
                          let window = box.event.window, window.isKeyWindow,
                          !(window.firstResponder is NSText), // 正在输入文字时不抢空格 / ⌘A / ⌘C
                          let raw = window.identifier?.rawValue, let id = UUID(uuidString: raw),
                          let handler = self.keyHandlers[id] else { return false }
                    return handler(box.event)
                }
                return consumed ? nil : event
            }
        }
    }

    func quickLookItem(_ url: URL) {
        let controller = QuickLookController(items: [url])
        quickLookController = controller
        controller.toggle()
    }

    func removeItem(id: UUID, from zoneID: UUID) {
        model.removeItem(id: id, from: zoneID)
    }

    // MARK: - 撤销上次真实移动

    /// 菜单栏：清理全部失效入口并报告数量。
    @objc func purgeNowMenuAction(_ sender: Any?) {
        let removed = model.purgeMissingEntries()
        inform(title: "清理失效入口", text: removed > 0 ? "移除了 \(removed) 个已不存在项目的入口。" : "没有发现失效入口。")
    }

    /// 菜单栏：关于——显示可执行文件路径与构建时间，便于确认运行的是否为最新版本。
    @objc func showAbout(_ sender: Any?) {
        let exe = Bundle.main.executablePath ?? "未知"
        let built = (try? FileManager.default.attributesOfItem(atPath: exe)[.modificationDate] as? Date) ?? nil
        let timeText = built.map { Self.dateFormatter.string(from: $0) } ?? "未知"
        inform(title: AppInfo.name, text: "版本：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")（液态玻璃）\n可执行文件：\(exe)\n构建时间：\(timeText)")
    }

    @objc func undoLastMove(_ sender: Any?) {
        let batch = model.undoBatch
        guard !batch.isEmpty else { return }
        let service = fileService
        // 进度显示在目标项目所在的分区里
        let zoneID = model.document.zones.first { zone in
            zone.items.contains { item in batch.contains { $0.destination.standardizedFileURL == item.url.standardizedFileURL } }
        }?.id
        runTransfer(zoneID: zoneID, title: "正在撤销移动…") { progress -> [MoveResult] in
            var results: [MoveResult] = []
            var stop = false
            for record in batch {
                if stop || progress.isCancelled { results.append(MoveResult(source: record.destination, status: .cancelled)); continue }
                let r = MoveResult.run(record.destination) {
                    try service.undo(record, progress: progress)
                    return (.moved(destination: record.source), nil)
                }
                if case .failed = r.status { stop = true } // 出错就停，后面的保持原样
                results.append(r)
            }
            return results
        } completion: { [weak self] results in
            guard let self else { return }
            let undone = zip(batch, results).compactMap { record, r -> MoveUndoRecord? in
                if case .moved = r.status { return record } else { return nil }
            }
            for record in undone {
                self.model.removeEntries(pointingTo: record.destination)
                // 撤销“移出分区”：文件回到了某个文件夹分区的关联文件夹，把入口加回去，免得成了看不见的孤儿
                let parent = FileOperationService.canonicalPath(record.source.deletingLastPathComponent())
                if let home = self.model.document.zones.first(where: { zone in
                    zone.kind == .folder && zone.backingFolderURL.map { FileOperationService.canonicalPath($0) } == parent
                }) {
                    self.model.addItem(ZoneItem(url: record.source, kind: FileTypeInspector.kind(of: record.source)), to: home.id)
                }
            }
            let remaining = batch.filter { !undone.contains($0) }
            self.model.setUndoBatch(remaining.isEmpty ? nil : remaining)
            if !undone.isEmpty {
                self.inform(title: "已撤销移动", text: "已把 \(undone.count) 个项目移回原位。")
            }
            self.reportProblems(results, verb: "撤销")
        }
    }

    // MARK: - 后台文件移动

    /// 在后台队列执行文件移动，期间分区显示进度、可取消；完成后回主线程更新布局。
    /// 同一时间只允许一个移动任务。
    private func runTransfer(
        zoneID: UUID?,
        title: String,
        work: @escaping @Sendable (TransferProgress) -> [MoveResult],
        completion: @escaping @MainActor ([MoveResult]) -> Void
    ) {
        guard !transfers.isBusy else {
            inform(title: "请稍候", text: "上一次移动还没完成，可以在分区里看到进度或点“取消”。")
            return
        }
        let (id, progress) = transfers.begin(zoneID: zoneID, title: title)
        DispatchQueue.global(qos: .userInitiated).async {
            let results = work(progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.transfers.finish(id)
                    completion(results)
                    if self.quitWhenTransferEnds {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
            }
        }
    }

    @objc func cancelTransfer(_ sender: Any?) {
        transfers.cancel()
    }

    /// 退出时如有移动进行中：取消它，等它把临时副本清理干净后再退出（源文件始终完好）。
    func prepareToQuit() -> NSApplication.TerminateReply {
        guard transfers.isBusy else { return .terminateNow }
        quitWhenTransferEnds = true
        suppressAlerts = true // 退出途中不弹任何对话框（否则会卡住注销 / 关机），提示留到下次启动
        transfers.cancel()
        return .terminateLater
    }

    private func reportProblems(_ results: [MoveResult], verb: String) {
        let failures = results.compactMap { r -> String? in
            if case .failed(let message) = r.status { return "\(r.source.lastPathComponent)：\(message)" }
            return nil
        }
        let cancelled = results.filter { if case .cancelled = $0.status { return true } else { return false } }.count
        if cancelled > 0 {
            inform(title: "已取消", text: "有 \(cancelled) 项没有\(verb)，原文件都保持不变。")
        }
        if !failures.isEmpty {
            inform(title: "有 \(failures.count) 项未能\(verb)", text: failures.prefix(3).joined(separator: "\n") + (failures.count > 3 ? "\n…" : ""))
        }
    }

    // MARK: - 退出自动归位（把拖入文件分区的文件放回桌面原位置）

    /// “退出自动归位”偏好键（默认开）。
    static let restoreOnQuitKey = "RestoreMovedFilesToDesktopOnQuit"
    /// 最近一次退出归位的报告（下次启动时提示用户）。
    static let lastRestoreReportKey = "LastAutoRestoreReport"

    /// 当前是否开启“退出时自动归位”（默认开启）。
    var isRestoreOnQuitEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.restoreOnQuitKey) as? Bool ?? true
    }

    /// 菜单栏开关。
    @objc func toggleRestoreOnQuit(_ sender: Any?) {
        let enabled = !isRestoreOnQuitEnabled
        UserDefaults.standard.set(enabled, forKey: Self.restoreOnQuitKey)
        restoreOnQuitMenuItem?.state = enabled ? .on : .off
    }

    /// 退出流程调用：开关开启时把拖入文件分区的文件放回桌面原位置，
    /// 并把结果存起来供下次启动提示。返回提示文案（空 = 无需提示）。
    @discardableResult
    func restoreMovedFilesToOriginalPlaces() -> String {
        guard isRestoreOnQuitEnabled else { return "" }
        let report = performRestoreToOriginalPlaces()
        if !report.isEmpty {
            UserDefaults.standard.set(report, forKey: Self.lastRestoreReportKey)
        }
        return report
    }

    /// 读取并清除“上次退出归位”报告。
    func consumeLastRestoreReport() -> String? {
        let value = UserDefaults.standard.string(forKey: Self.lastRestoreReportKey)
        if value != nil {
            UserDefaults.standard.removeObject(forKey: Self.lastRestoreReportKey)
        }
        return value
    }

    /// 核心归位逻辑。安全规则：
    /// - 只处理 kind == .folder 且条目真实位于其关联文件夹内的项目（虚拟 / 应用分区从不移动文件）；
    /// - 首选放回每个条目拖入前的原位置（movedFrom）；原位置未知或原目录已消失时回退到桌面根目录；
    /// - 原位置已有同名文件时不覆盖（留在分区），个别失败不阻断退出；
    /// - 已失效条目（文件已不在）直接移除入口。
    private func performRestoreToOriginalPlaces() -> String {
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else { return "" }
        let candidates = model.itemsMovedIntoZoneFolders(desktopURL: desktop)
        guard !candidates.isEmpty else { return "" }

        var moved = 0
        var kept: [String] = []
        var touchedZones = Set<UUID>()

        func removeEntry(_ candidate: MovedItemCandidate) {
            model.removeItem(id: candidate.item.id, from: candidate.zoneID)
            touchedZones.insert(candidate.zoneID)
        }

        for candidate in candidates {
            let item = candidate.item
            if !fm.fileExists(atPath: item.url.path) {
                removeEntry(candidate) // 文件已不在：清理失效入口
                continue
            }
            // 身份核对：移入时记录了文件编号，现在不一致 = 已被换成另一个同名文件，不动它。
            if let expected = item.movedFileNumber, Self.fileNumber(of: item.url) != expected {
                kept.append(item.url.lastPathComponent)
                continue
            }
            let fallback = desktop.appendingPathComponent(item.url.lastPathComponent)
            // 原位置只接受本地绝对路径，规范化后使用。
            let original = item.movedFrom.flatMap { $0.isFileURL ? $0.standardizedFileURL : nil }
            let targets = [original, fallback].compactMap { $0 }.filter { target in
                // 退出时只做同卷移动（瞬间完成）；跨卷需要复制，注销/关机时可能被打断留下半成品。
                Self.sameVolume(item.url, target.deletingLastPathComponent())
            }
            if targets.isEmpty {
                kept.append(item.url.lastPathComponent)
                continue
            }
            for target in targets {
                if target.standardizedFileURL == item.url.standardizedFileURL { continue }
                do {
                    let outcome = try fileService.moveBack(item: item.url, toOriginal: target)
                    switch outcome {
                    case .moved:
                        moved += 1
                        removeEntry(candidate)
                    case .cancelled:
                        kept.append(item.url.lastPathComponent) // 原位置被同名占用
                    }
                    break
                } catch FileOperationError.folderMissing {
                    continue // 原目录不存在 → 试下一个目标（桌面根目录）
                } catch {
                    kept.append(item.url.lastPathComponent)
                    break
                }
            }
        }

        if moved > 0 {
            model.clearUndo() // 位置已变，旧撤销记录作废
        }
        if !touchedZones.isEmpty {
            model.persistNow()
        }
        if moved == 0 && kept.isEmpty { return "" }
        var parts: [String] = []
        if moved > 0 {
            parts.append("已把 \(moved) 项放回桌面原位置")
        }
        if !kept.isEmpty {
            let names = kept.prefix(3).map { "“\($0)”" }.joined(separator: "、")
            let suffix = kept.count > 3 ? " 等 \(kept.count) 项" : ""
            parts.append("\(suffix.isEmpty ? "" : "")\(kept.count) 项因原位置已有同名文件未移动（\(names)\(kept.count > 3 ? "…" : "")）")
        }
        return parts.joined(separator: "；")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === undoMenuItem || menuItem.action == #selector(undoLastMove(_:)) {
            let count = model.undoBatch.count
            menuItem.title = count > 1 ? "撤销上次移动（\(count) 项）" : "撤销上次移动"
            menuItem.isEnabled = count > 0
            return menuItem.isEnabled
        }
        return true
    }

    @objc func restoreBackup(_ sender: NSMenuItem) {
        guard let backup = sender.representedObject as? BackupInfo else { return }
        do {
            var restored = try store.restoreBackup(backup)
            restored.lastMoveUndo = nil // 备份里的撤销记录早已过时
            model.replace(document: restored)
            // 关闭并重建全部窗口，让位置 / 收起 / 锁定都按备份重新应用
            for window in windows.values {
                window.delegate = nil
                window.close()
            }
            windows.removeAll()
            syncAllWindows()
            inform(title: "已恢复备份", text: "已从 \(Self.dateFormatter.string(from: backup.date)) 的备份恢复布局。")
        } catch {
            inform(title: "恢复失败", text: "无法读取该备份：\(error.localizedDescription)")
        }
    }

    func configureBackupSubmenu(_ menu: NSMenu) {
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let backups = store.availableBackups()
        if backups.isEmpty {
            let item = NSMenuItem(title: "暂无备份", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        for backup in backups {
            let item = NSMenuItem(
                title: Self.dateFormatter.string(from: backup.date),
                action: #selector(restoreBackup(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = backup
            menu.addItem(item)
        }
    }

    // MARK: - NSWindowDelegate：几何写回

    /// 分区不允许“缩放到全屏大小”：标题区双击（系统“双击标题栏缩放”）会把分区拉满屏。
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

    func windowDidMove(_ notification: Notification) {
        if isApplyingSnap {
            persistFrame(from: notification) // 吸附后的最终位置也要写回
            return
        }
        guard !programmaticFrameChange,
              let window = notification.object as? NSWindow,
              window.isVisible, !animatedMoveWindows.contains(window) else { return }
        persistFrame(from: notification)
        // 鼠标按住且非缩放：拖动分区 → 对齐吸附 + 虚线
        if NSEvent.pressedMouseButtons != 0, !window.inLiveResize {
            handleAlignmentDrag(window: window, allowSnap: true)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !programmaticFrameChange,
              let window = notification.object as? NSWindow,
              window.isVisible, !animatedMoveWindows.contains(window) else { return }
        persistFrame(from: notification)
        // 鼠标按住缩放分区：只显示对齐虚线（不吸附,避免和缩放打架）
        if NSEvent.pressedMouseButtons != 0, window.inLiveResize {
            handleAlignmentDrag(window: window, allowSnap: false)
        }
    }

    private func persistFrame(from notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let rawID = window.identifier?.rawValue,
              let zoneID = UUID(uuidString: rawID) else { return }
        // 折叠态下窗口尺寸是临时的小尺寸，不覆盖 zone.frame（保留展开尺寸）。
        guard let zone = model.zone(id: zoneID), !zone.appearance.collapsed else { return }
        let screenID = window.screen.map { "\($0.dshDisplayID)" } ?? ""
        model.updateFrame(zoneID: zoneID, rect: window.frame, screenID: screenID)
    }

    // MARK: - 对齐辅助线（边/中心吸附 + 画图软件式虚线）

    /// 拖动/缩放分区时的对齐入口。折叠条拖动不走窗口 delegate,由 moveCollapsedBar 直接调用吸附。
    private func handleAlignmentDrag(window: NSWindow, allowSnap: Bool) {
        guard let zone = zoneForWindow(window), !zone.locked else {
            hideAlignmentGuides()
            return
        }
        if zone.appearance.collapsed { return } // 折叠条由 moveCollapsedBar 统一管理,这里不清虚线
        if allowSnap {
            snapWindowToAlignment(window: window, zone: zone)
        } else {
            let result = AlignmentEngine.propose(rect: window.frame, among: alignmentCandidates(for: window))
            showGuides(result.guides, on: window.screen)
        }
    }

    /// 折叠条拖动时调用：把条吸附到同屏其它分区的边/中心,并同步展开矩形。
    /// - Parameters:
    ///   - window: 折叠条窗口
    ///   - proposed: 手势给出的目标 frame
    /// - Returns: 吸附后的 frame（调用方用于 setFrame 与展开矩形同步）
    @discardableResult
    func snappedCollapsedFrame(window: NSWindow, proposed: CGRect) -> CGRect {
        guard let zone = zoneForWindow(window), !zone.locked else {
            return proposed
        }
        let result = AlignmentEngine.propose(rect: proposed, among: alignmentCandidates(for: window))
        showGuides(result.guides, on: window.screen)
        return result.rect
    }

    private func snapWindowToAlignment(window: NSWindow, zone: Zone) {
        let result = AlignmentEngine.propose(rect: window.frame, among: alignmentCandidates(for: window))
        if result.rect != window.frame {
            isApplyingSnap = true
            window.setFrame(result.rect, display: true)
            isApplyingSnap = false
        }
        showGuides(result.guides, on: window.screen)
    }

    /// 同屏其它分区窗口的当前 frame（含折叠条,便于条与卡对齐）。
    private func alignmentCandidates(for window: NSWindow) -> [CGRect] {
        guard let screen = window.screen else { return [] }
        return windows.values
            .filter { $0 !== window && $0.screen === screen && $0.isVisible }
            .map(\.frame)
    }

    private func zoneForWindow(_ window: NSWindow) -> Zone? {
        guard let raw = window.identifier?.rawValue, let zoneID = UUID(uuidString: raw) else { return nil }
        return model.zone(id: zoneID)
    }

    private func showGuides(_ guides: [GuideLine], on screen: NSScreen?) {
        guard let screen, !guides.isEmpty else {
            hideAlignmentGuides()
            return
        }
        let id = screen.dshDisplayID
        let overlay = alignmentOverlays[id] ?? {
            let window = AlignmentOverlayWindow(screen: screen)
            alignmentOverlays[id] = window
            return window
        }()
        overlay.showLines(guides)
        installMouseUpMonitor()
    }

    /// 鼠标抬起时清除引导线（拖动 / 缩放结束）。
    private func installMouseUpMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.hideAlignmentGuides()
            return event
        }
    }

    private func hideAlignmentGuides() {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        // 拖动结束后释放全屏虚线窗口（整屏大小的后备缓冲约 10MB，不常驻）。
        for overlay in alignmentOverlays.values {
            overlay.showLines([])
            overlay.close()
        }
        alignmentOverlays.removeAll()
    }

    // MARK: - 折叠 / 展开

    /// 折叠时标题条窗口高度。
    static let collapsedWindowHeight: CGFloat = 36 // = ZoneView.headerHeight
    /// 展开态的最小窗口尺寸。
    static let expandedMinSize = NSSize(width: 240, height: 150)

    func setCollapsed(zoneID: UUID, collapsed: Bool) {
        guard let zone = model.zone(id: zoneID), let window = windows[zoneID] else { return }
        let updated = { () -> Zone in
            var z = zone
            z.appearance.collapsed = collapsed
            return z
        }()
        model.setCollapsed(zoneID: zoneID, collapsed: collapsed)
        applyCollapseState(zone: updated, window: window)
    }

    /// 安全网：一键展开所有收起的分区（菜单栏“展开全部收起的分区”）。
    /// 即使某条折叠条被壁纸“藏住”点不到，也能从这里恢复。
    @objc func expandAllCollapsedZones(_ sender: Any?) {
        for zone in model.document.zones where zone.appearance.collapsed {
            setCollapsed(zoneID: zone.id, collapsed: false)
        }
    }

    /// 拖动折叠条（无边框窗口不走系统标题栏拖动，这里用 SwiftUI 手势直接搬窗口）。
    /// 同时把展开矩形同步过去（底部贴住条身），这样展开时会出现在拖动后的位置。
    /// 按住空白处拖动分区（展开 / 收起都可以；锁定时不动）。吸附与对齐线照常。
    func moveZone(zoneID: UUID, translation: CGSize) {
        guard let window = windows[zoneID], let zone = model.zone(id: zoneID), !zone.locked else { return }
        if zone.appearance.collapsed {
            moveCollapsedBar(zoneID: zoneID, translation: translation)
            return
        }
        var frame = window.frame
        frame.origin.x += translation.width
        frame.origin.y -= translation.height // SwiftUI y 向下，屏幕坐标 y 向上
        frame = snappedCollapsedFrame(window: window, proposed: frame) // 同一套吸附 / 虚线
        programmaticFrameChange = true
        window.setFrame(frame, display: true)
        programmaticFrameChange = false
        let screenID = window.screen.map { "\($0.dshDisplayID)" } ?? ""
        model.updateFrame(zoneID: zoneID, rect: frame, screenID: screenID)
    }

    func moveCollapsedBar(zoneID: UUID, translation: CGSize) {
        guard let window = windows[zoneID],
              let zone = model.zone(id: zoneID),
              zone.appearance.collapsed, !zone.locked else { return }
        var frame = window.frame
        frame.origin.x += translation.width
        // SwiftUI 坐标 y 向下为正；AppKit/屏幕坐标 y 向上为正。
        frame.origin.y -= translation.height
        // 吸附到同屏其它分区（边 / 中心），并显示对齐虚线
        frame = snappedCollapsedFrame(window: window, proposed: frame)
        window.setFrame(frame, display: true)
        let expanded = CGRect(
            x: frame.minX,
            y: frame.maxY - zone.frame.height,
            width: zone.frame.width,
            height: zone.frame.height
        )
        let screenID = window.screen.map { "\($0.dshDisplayID)" } ?? ""
        model.updateFrame(zoneID: zoneID, rect: expanded, screenID: screenID)
    }

    /// 快捷设置窗口尺寸（更多菜单预设），并夹取进屏幕可见区域。
    func resizeZone(zoneID: UUID, size: CGSize) {
        guard let zone = model.zone(id: zoneID), let window = windows[zoneID] else { return }
        if zone.appearance.collapsed {
            // 先展开（同步改尺寸，避免两次动画叠加）
            var expanded = zone
            expanded.appearance.collapsed = false
            model.setCollapsed(zoneID: zoneID, collapsed: false)
            applyCollapseState(zone: expanded, window: window, animate: false)
        }
        guard let window = windows[zoneID] else { return }
        var rect = window.frame
        rect.size = size
        if let screen = window.screen {
            rect = FrameSanitizer.clamped(rect, into: screen.visibleFrame)
        }
        let screenID = window.screen.map { "\($0.dshDisplayID)" } ?? ""
        model.updateFrame(zoneID: zoneID, rect: rect, screenID: screenID)
        animatedMoveWindows.insert(window)
        programmaticFrameChange = true
        window.setFrame(rect, display: true, animate: true)
        programmaticFrameChange = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.animatedMoveWindows.remove(window)
        }
    }

    /// 收起/展开窗口高度动画时长（与 ZoneView.liquidMorph 一致，保证形态同步）。
    nonisolated static let morphDuration: TimeInterval = 0.32
    /// 收起 / 展开曲线：快出慢收、无回弹（与 SwiftUI timingCurve 一致）。
    private static let liquidCurve = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.24, 1.0)

    private func applyCollapseState(zone: Zone, window: NSWindow, animate: Bool = true) {
        // 窗口不可见时（启动恢复路径）做无动画的确定性设置：有动画时系统可能拒绝/延迟
        // 缩到目标尺寸，导致残留旧高度。
        let anim = animate && window.isVisible
        if zone.appearance.collapsed {
            // 折叠条用无边框窗口：.titled 总会保留 ~24pt 隐形标题栏并挤压内容（SafeArea），
            // 24pt 的条会变成 48pt 的窗口、文字还可能被裁剪。换成 borderless 后窗口即内容。
            window.styleMask = .borderless
            window.backgroundColor = .clear   // 切换 styleMask 可能重置背景，强制透明
            window.isOpaque = false
            window.hasShadow = false
            window.invalidateShadow()
            window.contentMinSize = NSSize(width: 160, height: Self.collapsedWindowHeight)
            window.level = currentLevel
            window.isMovableByWindowBackground = false // 拖动交给 SwiftUI 手势 moveCollapsedBar
            var frame = window.frame
            frame.origin.y = frame.maxY - Self.collapsedWindowHeight
            frame.size.height = Self.collapsedWindowHeight
            let zoneID = zone.id
            morphGeneration[zoneID, default: 0] += 1
            let generation = morphGeneration[zoneID]!
            if anim {
                // 先让玻璃在窗口里收上去（SwiftUI 动画），动画结束后再把窗口一步缩成薄条
                animatedMoveWindows.insert(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.morphDuration) { [weak self, weak window] in
                    guard let self, let window, self.morphGeneration[zoneID] == generation else { return }
                    defer { self.animatedMoveWindows.remove(window) }
                    guard self.model.zone(id: zoneID)?.appearance.collapsed == true else { return }
                    var final = window.frame
                    final.origin.y = final.maxY - Self.collapsedWindowHeight
                    final.size.height = Self.collapsedWindowHeight
                    self.moveWindow(window, to: final, animated: false)
                    window.invalidateShadow()
                }
            } else {
                moveWindow(window, to: frame, animated: false)
            }
        } else {
            window.contentMinSize = Self.expandedMinSize
            // 展开态同样用无边框窗口：带标题栏的窗口（即使透明隐藏）会把顶部约 28pt 的点击
            // 当成“拖窗口”，分区标题上的按钮（收起 / 锁 / 外观）就点不到。
            // borderless + resizable 仍可拖边缘缩放。
            var mask: NSWindow.StyleMask = [.borderless]
            if !zone.locked { mask.insert(.resizable) }
            window.styleMask = mask
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isMovableByWindowBackground = false // 拖动由空白区的 WindowDragHandle 显式处理（锁定时不动）
            hideTrafficLights(window) // 标题栏重建后重新隐藏红绿灯
            window.level = currentLevel
            // 展开：窗口一步到位到完整尺寸（顶边不动，下方透明），玻璃由 SwiftUI 从标题栏往下长出来
            var full = FrameSanitizer.cgRect(from: zone.frame)
            let top = window.frame.maxY
            full.origin.y = top - full.height
            full.origin.x = window.frame.minX
            moveWindow(window, to: full, animated: false)
            if FrameSanitizer.cgRect(from: zone.frame) != full {
                let screenID = window.screen.map { "\($0.dshDisplayID)" } ?? zone.screenID
                model.updateFrame(zoneID: zone.id, rect: full, screenID: screenID)
            }
            let zoneID = zone.id
            morphGeneration[zoneID, default: 0] += 1
            let generation = morphGeneration[zoneID]!
            if anim {
                animatedMoveWindows.insert(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.morphDuration + 0.05) { [weak self, weak window] in
                    guard let self, let window, self.morphGeneration[zoneID] == generation else { return }
                    self.animatedMoveWindows.remove(window)
                    window.invalidateShadow()
                }
            }
        }
    }

    /// 用与 SwiftUI 侧相同的液体曲线驱动窗口高度变化，实现连贯的收起/展开动画。
    private func moveWindow(_ window: NSWindow, to frame: NSRect, animated: Bool) {
        programmaticFrameChange = true
        defer { programmaticFrameChange = false }
        guard animated else {
            window.setFrame(frame, display: true, animate: false)
            return
        }
        animatedMoveWindows.insert(window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.morphDuration
            context.timingFunction = Self.liquidCurve
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            // 完成回调在主线程执行
            MainActor.assumeIsolated { _ = self?.animatedMoveWindows.remove(window) }
        }
        // 兜底：动画被中断时也要释放标记,避免后续拖动被误判为程序化。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.morphDuration + 0.2) { [weak self] in
            self?.animatedMoveWindows.remove(window)
        }
    }

    // MARK: - 窗口创建

    private func createWindow(for zone: Zone) {
        let hosting = FirstClickHostingView(rootView: ZoneView(manager: self, zoneID: zone.id))
        hosting.autoresizingMask = [.width, .height]
        // 窗口大小只由 Tuck 自己控制：不让 SwiftUI 按内容最小 / 理想尺寸去顶窗口。
        // 否则收起动画里窗口要缩到 36pt，而还没淡出的内容把最小高度顶回去，两边来回拉扯 → 一直抖。
        hosting.sizingOptions = []

        let style: NSWindow.StyleMask = [.borderless, .resizable]
        let rect = FrameSanitizer.cgRect(from: zone.frame)
        let window = DesktopFrameWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false // 拖动由 WindowDragHandle 显式处理
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.identifier = NSUserInterfaceItemIdentifier(zone.id.uuidString)
        window.contentMinSize = Self.expandedMinSize
        // 桌面图标之上、普通窗口之下；所有桌面空间都显示；“显示桌面”/调度中心时原地不动；
        // 不参与 ⌘` 窗口循环。
        window.level = currentLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.delegate = self
        window.contentView = hosting
        window.setFrame(rect, display: true)
        windows[zone.id] = window
        applyLockState(zone: zone, window: window)
        if zone.appearance.collapsed {
            applyCollapseState(zone: zone, window: window)
        }
        window.orderFrontRegardless() // 启动时不抢焦点
        hideTrafficLights(window) // 显示后再兜底一次：styleMask 变化可能重建标题栏按钮
    }

    /// 桌面浮窗不需要系统红绿灯（关闭/最小化/缩放三个圆点）。titled 窗口的标题栏在
    /// 样式变化（收起↔展开）时可能重建按钮，因此创建与每次展开后都要重藏。
    private func hideTrafficLights(_ window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
    }

    /// 锁定后移除可缩放样式并禁止整块拖动；解锁则恢复。
    /// 锁定后去掉边缘缩放；解锁恢复。整块拖动由空白区的 WindowDragHandle 按锁定状态处理。
    func applyLockState(zone: Zone, window: NSWindow) {
        window.isMovableByWindowBackground = false
        if zone.locked || zone.appearance.collapsed {
            window.styleMask.remove(.resizable)
        } else {
            window.styleMask.insert(.resizable)
        }
    }

    func toggleLock(zoneID: UUID) {
        guard let zone = model.zone(id: zoneID) else { return }
        var updated = zone
        updated.locked = !zone.locked
        model.setLocked(zoneID: zoneID, locked: updated.locked)
        if let window = windows[zoneID] {
            applyLockState(zone: updated, window: window)
        }
    }

    // MARK: - 新建分区的默认几何

    private func placementForNewZone() -> (frame: ZoneFrame, screenID: String) {
        let primary = NSScreen.screens.first(where: { $0.dshDescriptor.isPrimary }) ?? NSScreen.main
        let visible = primary?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let size = CGSize(width: 420, height: 300)
        let n = model.document.zones.count
        let step: CGFloat = 28
        let offset = CGFloat(n % 6)
        let origin = CGPoint(
            x: visible.minX + 60 + offset * step,
            y: visible.maxY - 60 - size.height - offset * step
        )
        let rect = FrameSanitizer.clamped(CGRect(origin: origin, size: size), into: visible)
        let screenID = primary.map { "\($0.dshDisplayID)" } ?? ""
        return (FrameSanitizer.zoneFrame(from: rect), screenID)
    }

    private func defaultName(for kind: ZoneKind) -> String {
        let count = model.document.zones.filter { $0.kind == kind }.count + 1
        return "\(kind.displayName) \(count)"
    }

    // MARK: - 通用对话框

    private func promptForBackingFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择或新建文件夹分区关联的真实文件夹"
        panel.prompt = "选择"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func promptForName(title: String, message: String, defaultText: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 退出流程中为 true：提示不弹框，改为存起来下次启动再显示。
    private var suppressAlerts = false
    static let pendingNoticeKey = "PendingNoticeOnLaunch"

    /// 读取并清除上次退出时留下的提示。
    func consumePendingNotice() -> String? {
        let value = UserDefaults.standard.string(forKey: Self.pendingNoticeKey)
        if value != nil { UserDefaults.standard.removeObject(forKey: Self.pendingNoticeKey) }
        return value
    }

    func inform(title: String, text: String) {
        if suppressAlerts {
            let old = UserDefaults.standard.string(forKey: Self.pendingNoticeKey).map { $0 + "\n" } ?? ""
            UserDefaults.standard.set(old + "\(title)：\(text)", forKey: Self.pendingNoticeKey)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 文件编号（inode），用于确认“还是当初移进来的那个文件”。
    static func fileNumber(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return number.uint64Value
    }

    /// 两个位置是否在同一个卷上。
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: key).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: key).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}

/// 桌面上的分区所在 App 平时不在前台：第一下点击就要生效（点胶囊直接展开、点按钮直接响应），
/// 不能先被“激活 App”吃掉。
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 一项文件移动的结果（从后台带回主线程）。
struct MoveResult: Sendable {
    enum Status: Sendable {
        case moved(destination: URL, replacedTrash: URL?)
        case skipped     // 冲突且选择了取消
        case cancelled   // 用户点了取消
        case failed(String)
    }
    let source: URL
    let status: Status

    static func run(_ source: URL, _ body: () throws -> (outcome: MoveOutcome, replacedTrashURL: URL?)) -> MoveResult {
        do {
            let r = try body()
            switch r.outcome {
            case .moved(let destination): return MoveResult(source: source, status: .moved(destination: destination, replacedTrash: r.replacedTrashURL))
            case .cancelled: return MoveResult(source: source, status: .skipped)
            }
        } catch FileOperationError.cancelled {
            return MoveResult(source: source, status: .cancelled)
        } catch {
            return MoveResult(source: source, status: .failed(error.localizedDescription))
        }
    }
}

/// 本地事件监听在主线程回调时，把 NSEvent 带进 MainActor.assumeIsolated（只在主线程使用）。
private struct MainThreadEventBox: @unchecked Sendable {
    let event: NSEvent
}
