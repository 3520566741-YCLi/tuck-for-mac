import AppKit
import DesktopFramesCore

/// 两种「下载直接进分区」：
/// 1. 下载分区：「Tuck 分区」里一个真实文件夹，浏览器下载到这里，分区里自动出现（侧栏点得到）；
/// 2. 新下载自动移进下载分区：看「下载」文件夹和桌面，新下载完成的文件移进下载分区的文件夹（用户明确要的「移动」，
///    只对打开后新下载完成的文件；同盘原子改名、重名加编号不覆盖；「撤销上次移动」放回原处；退出 Tuck 时文件留在那里）。
///
/// 安全底线：原有的桌面文件一概不碰（只认打开功能之后新出现的）；下载中的临时文件不收；
/// 下载分区的文件夹装的是用户的文件，Tuck 只读它的目录、永远不删它。
extension ZoneWindowManager {

    // MARK: - 1. 下载分区

    @objc func newDownloadZone(_ sender: Any?) {
        guard let id = createDownloadZone() else { return }
        // 还没开「新下载自动移进分区」：顺手问一下要不要让新下载都自动移到这里
        if collectZoneID == nil, let zone = model.zone(id: id), let folder = zone.backingFolderURL {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L("下载分区「\(zone.name)」建好了", "Download zone “\(zone.name)” is ready")
            alert.informativeText = L("要不要让以后浏览器下载完的文件都自动移到这里？不用改浏览器设置。\n\(folder.path)",
                                      "Move every new browser download here automatically? No browser settings to change.\n\(folder.path)")
            alert.addButton(withTitle: L("自动移到这里", "Move Downloads Here"))
            alert.addButton(withTitle: L("先不用", "Not Now"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { setCollectZone(id) }
        }
    }

    /// 建一个下载分区（问名字、建文件夹、建分区），返回新分区；取消 / 失败返回 nil。
    @discardableResult
    func createDownloadZone() -> UUID? {
        guard let name = promptForName(
            title: L("新建下载分区", "New Download Zone"),
            message: L("会在「Tuck 分区」里建一个同名的真实文件夹，里面的文件都显示在这个分区里。",
                       "Creates a real folder with this name inside “Tuck Zones”; everything in it shows in this zone."),
            defaultText: L("下载", "Downloads")
        ) else { return nil }
        guard let folder = ZoneMirror(root: zoneMirrorURL).makeDownloadFolder(named: name) else {
            inform(title: L("没能建好下载文件夹", "Couldn't create the download folder"),
                   text: L("「\(zoneMirrorURL.path)」不能用（可能是你自己的同名文件夹，里面已经有东西）。Tuck 没有改动它。",
                           "“\(zoneMirrorURL.path)” can't be used (it may be your own folder with the same name that already has things in it). Tuck left it untouched."))
            return nil
        }
        let placement = placementForNewZone()
        let zone = model.createZone(kind: .folder, name: name, frame: placement.frame, screenID: placement.screenID,
                                    backingFolderPath: folder.path, liveFolder: true)
        fillZoneGlassValues() // 新分区：通透自然的玻璃
        syncAllWindows()
        syncLiveFolders()
        refreshWatchedFolders()
        lastMirrorPlan = nil
        syncZoneMirror()
        return zone.id
    }

    /// 下载分区：把关联文件夹里现有的东西补成入口（下载中的临时文件、隐藏文件不算）。
    /// 文件被删 / 拖走后入口由 purgeMissingEntries 清掉。
    func syncLiveFolders() {
        let fm = FileManager.default
        for zone in model.document.zones where zone.liveFolder {
            guard let folder = zone.backingFolderURL,
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            var entries: [(url: URL, isDirectory: Bool)] = []
            for name in names.sorted() where !DownloadFiles.isIgnorable(name: name)
                && !name.hasPrefix(FileOperationService.partialPrefix) {
                let url = folder.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                // 软件包（.app 等）当文件看
                let directory = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
                entries.append((url, directory))
            }
            model.syncLiveFolder(zoneID: zone.id, entries: entries)
        }
    }

    // MARK: - 2. 新下载自动收进分区（「下载」文件夹 + 桌面，不用改浏览器设置）

    static let collectZoneKey = "CollectDesktopDownloadsZone"
    static let collectScreenshotsKey = "CollectScreenshots"
    static let screenshotZoneKey = "CollectScreenshotsZone"
    static let downloadsExplainedKey = "CollectDownloadsExplained"

    /// 新下载移进哪个下载分区（没选 / 那个分区已删 = 关）。
    var collectZoneID: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: Self.collectZoneKey), let id = UUID(uuidString: raw),
              let zone = model.zone(id: id), zone.liveFolder, zone.backingFolderURL != nil else { return nil }
        return id
    }

    /// 截图也收（默认关）。
    var collectScreenshots: Bool { UserDefaults.standard.bool(forKey: Self.collectScreenshotsKey) }

    /// 截图放进哪个下载分区（没选 / 已删 = 和其它新文件放同一个分区）。
    var screenshotZoneID: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: Self.screenshotZoneKey), let id = UUID(uuidString: raw),
              let zone = model.zone(id: id), zone.liveFolder, zone.backingFolderURL != nil else { return nil }
        return id
    }

    func setCollectScreenshots(_ on: Bool) { UserDefaults.standard.set(on, forKey: Self.collectScreenshotsKey) }

    func setScreenshotZone(_ id: UUID?) {
        if let id { UserDefaults.standard.set(id.uuidString, forKey: Self.screenshotZoneKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.screenshotZoneKey) }
    }

    /// 系统的「下载」文件夹（浏览器默认下载到这里）。测试 / 截图用的独立实例不看真实的「下载」，
    /// 除非用 DESKTOPFRAMES_DOWNLOADS_DIR 指定一个测试目录。
    var downloadsURL: URL? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["DESKTOPFRAMES_DOWNLOADS_DIR"], dir.hasPrefix("/") { return URL(fileURLWithPath: dir, isDirectory: true) }
        if env["DESKTOPFRAMES_DATA_DIR"] != nil { return nil }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// 要看着的文件夹：「下载」+ 桌面。
    private var collectFolders: [URL] {
        var result: [URL] = []
        if let downloads = downloadsURL { result.append(downloads) }
        if let desktop = desktopURL, !result.contains(where: { $0.standardizedFileURL == desktop.standardizedFileURL }) {
            result.append(desktop)
        }
        return result
    }

    func setCollectZone(_ id: UUID?) {
        if let id {
            pendingCollectZone = id
            explainDownloadsAccessIfNeeded()
            pendingCollectZone = nil
            UserDefaults.standard.set(id.uuidString, forKey: Self.collectZoneKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.collectZoneKey)
        }
        refreshDesktopCollector()
        if id != nil, let downloads = downloadsURL, downloadCollectors[downloads.standardizedFileURL.path] == nil {
            inform(title: L("没能看「下载」文件夹", "Can't see the Downloads folder"),
                   text: L("系统没让 Tuck 读「下载」文件夹，所以那里的新下载收不进来（桌面上的照常收）。\n去 系统设置 › 隐私与安全性 › 文件与文件夹 › Tuck，打开「下载文件夹」，再回菜单里选一次分区。",
                           "macOS didn't let Tuck read the Downloads folder, so new downloads there can't be collected (Desktop downloads still are).\nGo to System Settings › Privacy & Security › Files & Folders › Tuck, turn on Downloads Folder, then pick the zone again in the menu."))
        }
    }

    /// 第一次打开时先说清楚：新下载会被移走、「下载」里不再保留；接着系统会问一次「下载」文件夹权限。
    private func explainDownloadsAccessIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.downloadsExplainedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.downloadsExplainedKey)
        let target = collectTargetDescription
        inform(title: L("新下载会自动移进分区", "New downloads will move into the zone"),
               text: L("以后新存到「下载」文件夹或桌面上的文件（浏览器下载、网页里「另存为」、别的软件保存都算，截图默认不算），会被移到\(target)，原处不再保留，分区里看到的就是它。原来就有的文件不动。\n想放回去：菜单栏「撤销上次移动」，或把它从分区拖出去。\n接下来系统会问一次能不能读「下载」文件夹，请点「允许」。",
                       "From now on, new files saved to Downloads or the Desktop (browser downloads, Save As from a web page, saves from other apps; not screenshots by default) are moved to \(target) and don't stay behind; the zone shows them. Existing files are left alone.\nTo put one back: Undo Last Move in the menu bar, or drag it out of the zone.\nmacOS will ask once whether Tuck can read the Downloads folder. Please click Allow."))
    }

    private var collectTargetDescription: String {
        guard let id = collectZoneID ?? pendingCollectZone, let folder = model.zone(id: id)?.backingFolderURL else { return L("下载分区", "the download zone") }
        return "「\(folder.path)」"
    }

    /// 有没有程序正打开着这个文件（还在写 / 正在用）：有就先不搬，免得影响那个软件。
    /// 只看得到自己用户的程序；看不到的当作没开（同时还要求连续两次大小不变）。
    static func isOpenByAnyProcess(_ path: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, buffer.baseAddress, Int32(buffer.count))
        }
        return bytes > 0
    }

    /// 开着就监听「下载」和桌面（第一次看时记下里面现有的全部东西，它们永远不会被收）；关了就停。
    func refreshDesktopCollector() {
        guard collectZoneID != nil else {
            desktopCollectWatcher?.stop()
            desktopCollectWatcher = nil
            desktopCollectRetry?.cancel()
            downloadCollectors.removeAll()
            return
        }
        var changed = false
        for folder in collectFolders {
            let key = folder.standardizedFileURL.path
            guard downloadCollectors[key] == nil else { continue }
            // 读不了（没给权限）就先不看这个文件夹，下次刷新再试
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            downloadCollectors[key] = DesktopDownloadCollector(baseline: names)
            changed = true
        }
        guard changed || desktopCollectWatcher == nil else { return }
        if desktopCollectWatcher == nil {
            desktopCollectWatcher = FolderWatcher { [weak self] in self?.collectDesktopDownloads() }
        }
        desktopCollectWatcher?.watch(paths: Set(downloadCollectors.keys))
    }

    /// 看一次：「下载」和桌面里确认写完的新文件，移进下载分区的文件夹（分区里自动出现）。
    /// 只用同一块磁盘上的原子改名（不复制），重名加编号、绝不覆盖；可以用「撤销上次移动」放回原处。
    func collectDesktopDownloads() {
        desktopCollectRetry?.cancel()
        guard let zoneID = collectZoneID, let target = model.zone(id: zoneID)?.backingFolderURL else { return }
        let shotTarget = screenshotZoneID.flatMap { model.zone(id: $0)?.backingFolderURL } ?? target
        let includeShots = collectScreenshots
        let fm = FileManager.default
        var anyPending = false
        var records: [MoveUndoRecord] = []
        // 已经是某个分区的入口（比如在分区里「制作替身」「压缩」「新建文件夹」刚做出来的桌面文件）：不搬
        let inZones = Set(model.document.zones.flatMap { $0.items.map { $0.url.standardizedFileURL.path } })
        for (key, var collector) in downloadCollectors {
            let folder = URL(fileURLWithPath: key, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            var entries: [DesktopDownloadCollector.Entry] = []
            for name in names {
                guard collector.needsLook(name) else {
                    entries.append(.init(name: name, size: 0, createdAt: nil))
                    continue
                }
                let url = folder.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                // 是 Tuck 刚移进分区、又被拿回来的同一个文件（拖回桌面 / 撤销），或者已经是分区入口：不再收
                if movedOutInodes.contains(UInt64(st.st_ino)) || inZones.contains(url.standardizedFileURL.path) {
                    collector.forget(name)
                    entries.append(.init(name: name, size: 0, createdAt: nil))
                    continue
                }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                let created = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
                entries.append(.init(
                    name: name,
                    size: isDir ? 1 : Int64(st.st_size),
                    createdAt: created,
                    isScreenshot: DownloadFiles.isScreenshot(url: url),
                    inUse: !isDir && Self.isOpenByAnyProcess(url.path)
                ))
            }
            for item in collector.step(entries, now: Date(), includeScreenshots: includeShots) {
                let source = folder.appendingPathComponent(item.name)
                var st = stat()
                let inode = lstat(source.path, &st) == 0 ? UInt64(st.st_ino) : 0
                if let moved = DownloadMover.move(source, into: item.isScreenshot ? shotTarget : target) {
                    records.append(MoveUndoRecord(source: source, destination: moved))
                    if inode != 0 { movedOutInodes.insert(inode) }
                }
            }
            anyPending = anyPending || collector.hasPending
            downloadCollectors[key] = collector
        }
        if !records.isEmpty {
            model.setUndoBatch(records) // 菜单栏「撤销上次移动」= 放回原处
            syncLiveFolders()
        }
        // 还有没下完 / 刚出现的：过一会儿再看（文件写入时文件夹本身不一定会通知）
        if anyPending {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.collectDesktopDownloads() }
            }
            desktopCollectRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }
}

/// 把下载好的文件移进下载分区的文件夹：同一块磁盘上原子改名，目标已有同名的就加编号，绝不覆盖。
enum DownloadMover {
    /// 返回移过去的新位置；不同磁盘 / 失败返回 nil（文件留在原处不动）。
    static func move(_ source: URL, into folder: URL) -> URL? {
        guard sameVolume(source.deletingLastPathComponent(), folder) else { return nil }
        let name = source.lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 1...200 {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            let destination = folder.appendingPathComponent(candidate)
            // RENAME_EXCL：目标已存在就失败（不会覆盖），换下一个编号
            if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        return stat(a.path, &sa) == 0 && stat(b.path, &sb) == 0 && sa.st_dev == sb.st_dev
    }
}

/// 菜单栏「新下载自动收进」子菜单：每次打开时按当前分区重新列。
@MainActor
final class CollectDownloadsMenu: NSObject, NSMenuDelegate {
    weak var manager: ZoneWindowManager?

    init(manager: ZoneWindowManager) {
        self.manager = manager
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let manager else { return }
        let current = manager.collectZoneID
        let off = NSMenuItem(title: L("关闭", "Off"), action: #selector(pick(_:)), keyEquivalent: "")
        off.target = self
        off.state = current == nil ? .on : .off
        menu.addItem(off)
        for zone in manager.model.document.zones where zone.liveFolder {
            let item = NSMenuItem(title: zone.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = zone.id.uuidString
            item.state = current == zone.id ? .on : .off
            menu.addItem(item)
        }
        let create = NSMenuItem(title: L("新建下载分区并移到这里…", "New Download Zone and Move Here…"), action: #selector(createAndPick(_:)), keyEquivalent: "")
        create.target = self
        menu.addItem(create)
        menu.addItem(.separator())
        let shots = NSMenuItem(title: L("截图也收", "Include Screenshots"), action: #selector(toggleScreenshots(_:)), keyEquivalent: "")
        shots.target = self
        shots.state = manager.collectScreenshots ? .on : .off
        menu.addItem(shots)
        if manager.collectScreenshots {
            let shotZone = manager.screenshotZoneID
            let same = NSMenuItem(title: L("截图放进：同一个分区", "Screenshots go to: the same zone"), action: #selector(pickShotZone(_:)), keyEquivalent: "")
            same.target = self
            same.indentationLevel = 1
            same.state = shotZone == nil ? .on : .off
            menu.addItem(same)
            for zone in manager.model.document.zones where zone.liveFolder && zone.id != current {
                let item = NSMenuItem(title: L("截图放进：\(zone.name)", "Screenshots go to: \(zone.name)"), action: #selector(pickShotZone(_:)), keyEquivalent: "")
                item.target = self
                item.indentationLevel = 1
                item.representedObject = zone.id.uuidString
                item.state = shotZone == zone.id ? .on : .off
                menu.addItem(item)
            }
        }
        let hint = NSMenuItem(title: L("打开后新存到「下载」/ 桌面的文件（下载、另存为、别的软件保存）移进这个分区，原处不再保留；「撤销上次移动」可放回",
                                       "New files saved to Downloads / Desktop (downloads, Save As, other apps) move into this zone; Undo Last Move puts one back"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    @objc private func createAndPick(_ sender: NSMenuItem) {
        guard let manager, let id = manager.createDownloadZone() else { return }
        manager.setCollectZone(id)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        manager?.setCollectZone(id)
    }

    @objc private func toggleScreenshots(_ sender: NSMenuItem) {
        guard let manager else { return }
        manager.setCollectScreenshots(!manager.collectScreenshots)
    }

    @objc private func pickShotZone(_ sender: NSMenuItem) {
        manager?.setScreenshotZone((sender.representedObject as? String).flatMap(UUID.init(uuidString:)))
    }
}
