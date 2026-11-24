import AppKit
import DesktopFramesCore
import SwiftUI

/// 分区里文件 / 文件夹的“访达同款”操作：移到废纸篓、显示简介、重新命名、复制、压缩、制作替身、
/// 拷贝 / 粘贴、共享、颜色标签、打开方式。
///
/// 安全底线（Tuck 一贯的规矩）：
/// - 删除只有“移到废纸篓”，绝不直接删除；废纸篓里的东西可以用菜单栏“撤销上次移动”（或 ⌘Z）拿回原位；
/// - 绝不覆盖已有文件：改名撞名会提示，复制 / 压缩 / 替身自动另起名字；
/// - 被 Tuck 藏起来的桌面原文件：动它之前先恢复显示，免得带着“隐藏”去了别处（例如废纸篓里看不见）。
extension ZoneWindowManager {

    // MARK: - 移到废纸篓

    /// 把这些项目移到废纸篓（和访达 ⌘⌫ 一样，不弹确认）。入口随之从分区消失；
    /// 菜单栏“撤销上次移动”/ ⌘Z 会把文件放回原位、入口加回原分区。
    func trashItems(_ items: [ZoneItem], zoneID: UUID) {
        let fm = FileManager.default
        let present = items.filter { fm.fileExists(atPath: $0.url.path) }
        let missing = items.filter { !fm.fileExists(atPath: $0.url.path) }
        for item in missing { model.removeItem(id: item.id, from: zoneID) } // 早就不在了：只清入口
        guard !present.isEmpty else { return }
        let zoneKind = model.zone(id: zoneID)?.kind
        releaseHidden(present.map(\.url))
        var records: [MoveUndoRecord] = []
        var failures: [String] = []
        for item in present {
            do {
                var resulting: NSURL?
                try fm.trashItem(at: item.url, resultingItemURL: &resulting)
                model.removeEntries(pointingTo: item.url)
                if let trashed = resulting as URL? {
                    records.append(MoveUndoRecord(
                        source: item.url, destination: trashed,
                        // 文件分区的入口由“回到关联文件夹”自动加回；普通 / 应用分区要记下来
                        restoreZoneID: zoneKind == .folder ? nil : zoneID
                    ))
                }
            } catch {
                failures.append("\(item.url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !records.isEmpty {
            model.setUndoBatch(records)
            Self.playTrashSound()
        }
        reconcileDesktopHiding()
        if !failures.isEmpty {
            inform(title: L("有 \(failures.count) 项未能移到废纸篓", "Couldn't move \(failures.count) item(s) to the Trash"),
                   text: failures.prefix(3).joined(separator: "\n") + (failures.count > 3 ? "\n…" : ""))
        }
    }

    /// 访达同款“扔进废纸篓”的声音（系统设置里关掉了“界面音效”就不响）。
    private static func playTrashSound() {
        let enabled = UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int ?? 1
        guard enabled != 0 else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    // MARK: - 显示简介

    /// 打开访达的“简介”窗口（⌘I）。先走访达自己提供的系统服务（不需要任何权限），
    /// 不行再请访达打开（第一次会请求“自动化”权限）。
    func showInfo(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        let pb = NSPasteboard(name: NSPasteboard.Name("io.github.tuckformac.tuck.showinfo"))
        pb.clearContents()
        pb.writeObjects(existing.map { $0 as NSURL })
        if NSPerformService("Finder/Show Info", pb) { return }
        let list = existing.map { "POSIX file \"\(Self.appleScriptEscaped($0.path))\"" }.joined(separator: ", ")
        let source = """
        tell application "Finder"
            activate
            repeat with f in {\(list)}
                open information window of (f as alias)
            end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            // 实在打不开：退而求其次，在访达里选中它（用户可以自己按 ⌘I）
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    private static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - 重新命名

    /// 重命名（分区里直接改名后调用）。成功返回 true；撞名 / 非法名字会提示并返回 false。
    /// 入口跟着新名字走，在分区里的位置不变。
    @discardableResult
    func renameItem(_ item: ZoneItem, to rawName: String) -> Bool {
        let fm = FileManager.default
        let old = item.url
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old.lastPathComponent else { return false }
        guard fm.fileExists(atPath: old.path) else {
            informMissingAndRemove(url: old)
            return false
        }
        if name.contains("/") || name.contains(":") || name == "." || name == ".." {
            inform(title: L("无法重新命名", "Can't rename"), text: L("名称里不能有“/”或“:”。", "The name can't contain “/” or “:”."))
            return false
        }
        if name.hasPrefix(".") {
            inform(title: L("无法重新命名", "Can't rename"), text: L("以“.”开头的名字是系统隐藏文件专用的，请换一个名字。", "Names starting with “.” are reserved for hidden system files. Please choose another name."))
            return false
        }
        let isDirectory = (try? old.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let isPackage = (try? old.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        // 改了扩展名（文件 / 包）：和访达一样先确认，免得文件打不开
        if !isDirectory || isPackage {
            let oldExt = old.pathExtension, newExt = (name as NSString).pathExtension
            if !oldExt.isEmpty, oldExt.lowercased() != newExt.lowercased(), !confirmExtensionChange(from: oldExt, to: newExt) {
                return false
            }
        }
        let dest = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isDirectory)
        // 只改大小写（a.txt → A.txt）在不区分大小写的磁盘上“目标已存在”其实就是它自己
        let sameFile = Self.fileNumber(of: dest).map { $0 == Self.fileNumber(of: old) } ?? false
        if fm.fileExists(atPath: dest.path), !sameFile {
            inform(title: L("无法重新命名", "Can't rename"), text: L("这里已经有一个叫“\(name)”的项目，请换一个名字。", "There's already an item named “\(name)” here. Please choose another name."))
            return false
        }
        releaseHidden([old])
        do {
            try fm.moveItem(at: old, to: dest)
        } catch {
            reconcileDesktopHiding()
            inform(title: L("无法重新命名", "Can't rename"), text: error.localizedDescription)
            return false
        }
        model.retargetEntries(from: old, to: dest)
        reconcileDesktopHiding() // 新名字的桌面原图标照样藏起来
        return true
    }

    private func confirmExtensionChange(from oldExt: String, to newExt: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if newExt.isEmpty {
            alert.messageText = L("确定要移除扩展名“.\(oldExt)”吗？", "Are you sure you want to remove the extension “.\(oldExt)”?")
        } else {
            alert.messageText = L("确定要将扩展名“.\(oldExt)”更改为“.\(newExt)”吗？", "Are you sure you want to change the extension from “.\(oldExt)” to “.\(newExt)”?")
        }
        alert.informativeText = L("更改扩展名后，文件可能会用另一个应用打开。", "If you make this change, your document may open in a different app.")
        alert.addButton(withTitle: L("保留“.\(oldExt)”", "Keep “.\(oldExt)”"))
        alert.addButton(withTitle: newExt.isEmpty ? L("移除", "Remove") : L("使用“.\(newExt)”", "Use “.\(newExt)”"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - 复制（⌘D）/ 制作替身 / 压缩

    /// 复制：在原项目旁边生成“名字 副本”，并紧挨着原项目出现在分区里。
    func duplicateItems(_ items: [ZoneItem], zoneID: UUID) {
        let fm = FileManager.default
        let present = items.filter { fm.fileExists(atPath: $0.url.path) }
        guard !present.isEmpty else { return }
        let service = fileService
        let plan = present.map { (id: $0.id, source: $0.url) }
        let title = present.count == 1
            ? L("正在复制“\(present[0].url.lastPathComponent)”…", "Duplicating “\(present[0].url.lastPathComponent)”…")
            : L("正在复制 \(present.count) 项…", "Duplicating \(present.count) items…")
        runTransfer(zoneID: zoneID, title: title) { progress -> [MoveResult] in
            plan.map { entry in
                if progress.isCancelled { return MoveResult(source: entry.source, status: .cancelled) }
                return MoveResult.run(entry.source) {
                    let dest = service.duplicateDestination(for: entry.source)
                    return (.moved(destination: try service.duplicate(item: entry.source, to: dest, progress: progress)), nil)
                }
            }
        } completion: { [weak self] results in
            guard let self else { return }
            for (entry, r) in Swift.zip(plan, results) {
                guard case .moved(let destination, _) = r.status else { continue }
                self.model.insertItem(ZoneItem(url: destination, kind: FileTypeInspector.kind(of: destination)), after: entry.id, in: zoneID)
            }
            self.reconcileDesktopHiding()
            self.reportProblems(results, verb: L("复制", "duplicate"))
        }
    }

    /// 制作替身：放在原项目旁边（“名字 的替身”），也加进分区。
    func makeAliasItems(_ items: [ZoneItem], zoneID: UUID) {
        for item in items where FileManager.default.fileExists(atPath: item.url.path) {
            for alias in makeAliases([item.url]) {
                model.insertItem(ZoneItem(url: alias, kind: FileTypeInspector.kind(of: alias)), after: item.id, in: zoneID)
            }
        }
        reconcileDesktopHiding()
    }

    /// 压缩：一项 →“名字.zip”（和访达一样保留文件夹本身、扩展属性和资源分支）；
    /// 多项（在同一个文件夹里）→“归档.zip”。压缩包放在原项目旁边，并加进分区。
    func compressItems(_ items: [ZoneItem], zoneID: UUID) {
        let fm = FileManager.default
        let present = items.filter { fm.fileExists(atPath: $0.url.path) }
        guard !present.isEmpty else { return }
        let folder = present[0].url.deletingLastPathComponent()
        let folderPath = FileOperationService.canonicalPath(folder)
        guard present.allSatisfy({ FileOperationService.canonicalPath($0.url.deletingLastPathComponent()) == folderPath }) else {
            inform(title: L("无法压缩", "Can't compress"), text: L("一起压缩的项目要在同一个文件夹里。可以分开压缩，或先放到同一个文件夹。", "Items compressed together must be in the same folder. Compress them separately, or put them in one folder first."))
            return
        }
        let single = present.count == 1
        let baseName = single ? present[0].url.lastPathComponent : L("归档", "Archive")
        var archive = folder.appendingPathComponent(baseName + ".zip")
        var n = 2
        while fm.fileExists(atPath: archive.path) {
            archive = folder.appendingPathComponent("\(baseName) \(n).zip")
            n += 1
        }
        let sources = present.map(\.url)
        // 被 Tuck 藏起来的桌面原文件先恢复显示，否则压缩包里的它解压出来也是隐藏的；压完再对账藏回去
        if !transfers.isBusy { releaseHidden(sources) } // 忙的时候 runTransfer 会提示稍候，不动任何东西
        let target = archive
        let anchor = present.last?.id
        let title = single
            ? L("正在压缩“\(baseName)”…", "Compressing “\(baseName)”…")
            : L("正在压缩 \(present.count) 项…", "Compressing \(present.count) items…")
        runTransfer(zoneID: zoneID, title: title) { progress -> [MoveResult] in
            [MoveResult.run(target) {
                try Self.zip(sources, into: target, workingDirectory: folder, progress: progress)
                return (.moved(destination: target), nil)
            }]
        } completion: { [weak self] results in
            guard let self else { return }
            if case .moved(let destination, _) = results.first?.status {
                self.model.insertItem(ZoneItem(url: destination, kind: .file), after: anchor, in: zoneID)
            }
            self.reconcileDesktopHiding()
            self.reportProblems(results, verb: L("压缩", "compress"))
        }
    }

    /// 后台压缩：先写到隐藏临时名，成功后再改成正式名字（失败 / 取消不留半截文件）。
    nonisolated private static func zip(_ sources: [URL], into archive: URL, workingDirectory: URL, progress: TransferProgress) throws {
        let temp = archive.deletingLastPathComponent().appendingPathComponent("\(FileOperationService.partialPrefix)\(UUID().uuidString).zip")
        let process = Process()
        if sources.count == 1 {
            // 访达“压缩”用的就是 ditto：保留扩展属性、资源分支、权限
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0].path, temp.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = workingDirectory
            // -y 保留符号链接本身（不跟进去打包别处的文件）；-X 不写多余的系统属性；用相对名字，压缩包里不带完整路径
            process.arguments = ["-r", "-y", "-q", "-X", temp.path, "--"] + sources.map(\.lastPathComponent)
        }
        process.standardOutput = FileHandle.nullDevice
        // 错误输出边读边收（最多留 8KB）：不读的话管道写满（约 64KB），zip 会卡住永远不退出
        let errPipe = Pipe()
        process.standardError = errPipe
        let errBuffer = StderrBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { handle in errBuffer.append(handle.availableData) }
        defer { errPipe.fileHandleForReading.readabilityHandler = nil }
        try process.run()
        while process.isRunning {
            if progress.isCancelled {
                process.terminate()
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: temp)
                throw FileOperationError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: temp)
            let message = errBuffer.text
            throw FileOperationError.underlying(message.isEmpty ? L("压缩失败", "Compression failed") : message)
        }
        if renamex_np(temp.path, archive.path, UInt32(RENAME_EXCL)) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw FileOperationError.occupied(archive)
        }
    }

    // MARK: - 拷贝 / 粘贴

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    /// 剪贴板里的文件（只认本地文件）。
    static func pasteboardFileURLs() -> [URL] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 粘贴到分区：文件分区 = 复制进关联文件夹（和在访达里粘贴一样）；普通 / 应用分区 = 只加入口（不动文件）。
    func pasteIntoZone(_ zoneID: UUID) {
        let urls = Self.pasteboardFileURLs()
        guard !urls.isEmpty, let zone = model.zone(id: zoneID) else { return }
        if zone.kind == .folder, let folder = zone.backingFolderURL {
            transferIntoFolder(urls: urls, folder: folder, copy: true, zoneID: zoneID, addingEntriesTo: zoneID)
        } else {
            drop(urls: urls, into: zoneID)
        }
    }

    /// 粘贴到分区里的某个文件夹（右键文件夹 → 粘贴项目）。
    func paste(intoFolder folder: URL, zoneID: UUID) {
        let urls = Self.pasteboardFileURLs()
        guard !urls.isEmpty else { return }
        transferIntoFolder(urls: urls, folder: folder, copy: true, zoneID: zoneID)
    }

    // MARK: - 新建文件夹（文件分区）

    /// 在文件分区的关联文件夹里新建“未命名文件夹”，返回它在分区里的入口 ID（接着进入改名）。
    func newFolder(in zoneID: UUID) -> UUID? {
        guard let zone = model.zone(id: zoneID), zone.kind == .folder, let folder = zone.backingFolderURL else { return nil }
        let fm = FileManager.default
        let base = L("未命名文件夹", "untitled folder")
        var url = folder.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            inform(title: L("无法新建文件夹", "Couldn't create the folder"), text: error.localizedDescription)
            return nil
        }
        let item = ZoneItem(url: url, kind: .folder)
        model.addItem(item, to: zoneID)
        return item.id
    }

    // MARK: - 打开方式

    /// “打开方式”子菜单：默认应用排第一，其余按名字排；最后是“其他…”。
    func openWithMenu(for urls: [URL]) -> NSMenu? {
        guard let first = urls.first else { return nil }
        let ws = NSWorkspace.shared
        let defaultApp = ws.urlForApplication(toOpen: first)
        var apps = ws.urlsForApplications(toOpen: first)
        // 多选：只列大家都能打开的应用
        for url in urls.dropFirst() {
            let allowed = Set(ws.urlsForApplications(toOpen: url).map(\.standardizedFileURL))
            apps = apps.filter { allowed.contains($0.standardizedFileURL) }
        }
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let others = apps.filter { $0.standardizedFileURL != defaultApp?.standardizedFileURL }
            .sorted { Self.appName($0).localizedStandardCompare(Self.appName($1)) == .orderedAscending }
        let menu = NSMenu()
        func add(_ app: URL, isDefault: Bool) {
            let title = isDefault ? L("\(Self.appName(app))（默认）", "\(Self.appName(app)) (default)") : Self.appName(app)
            let item = ClosureMenuItem(title) { [weak self] in self?.open(urls, with: app) }
            let icon = ws.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if let defaultApp, apps.contains(where: { $0.standardizedFileURL == defaultApp.standardizedFileURL }) || urls.count == 1 {
            add(defaultApp, isDefault: true)
            if !others.isEmpty { menu.addItem(.separator()) }
        }
        for app in others.prefix(30) { add(app, isDefault: false) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(L("其他…", "Other…")) { [weak self] in self?.chooseAppAndOpen(urls) })
        return menu
    }

    private static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func open(_ urls: [URL], with app: URL) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.open(existing, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func chooseAppAndOpen(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("打开", "Open")
        panel.message = L("选择用来打开的应用", "Choose an app to open with")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(urls, with: app)
    }

    // MARK: - 颜色标签

    /// 切换颜色标签（和访达一样：选中的都有这个标签就去掉，否则全部加上）。
    func toggleTag(labelIndex: Int, on urls: [URL]) {
        guard let name = FinderTags.name(for: labelIndex) else { return }
        let allHave = urls.allSatisfy { FinderTags.tagNames(of: $0).contains(name) }
        for url in urls {
            var tags = FinderTags.tagNames(of: url)
            if allHave {
                tags.removeAll { $0 == name }
            } else if !tags.contains(name) {
                tags.append(name)
            }
            try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            FinderTags.invalidate(url)
        }
        model.objectWillChange.send() // 让分区里的色点立即刷新
    }
}

// MARK: - 颜色标签：读取 / 缓存 / 色点

/// 访达颜色标签。系统给的名字已按用户语言本地化（“红色”/“Red”…），颜色按访达的序号取。
@MainActor
enum FinderTags {
    /// 访达菜单里的颜色顺序：红 橙 黄 绿 蓝 紫 灰（对应系统标签序号）。
    static let menuOrder = [6, 7, 5, 2, 4, 3, 1]

    static func name(for index: Int) -> String? {
        let labels = NSWorkspace.shared.fileLabels
        return labels.indices.contains(index) ? labels[index] : nil
    }

    static func color(for index: Int) -> NSColor {
        let colors = NSWorkspace.shared.fileLabelColors
        return colors.indices.contains(index) ? colors[index] : .gray
    }

    nonisolated static func tagNames(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    private struct Entry { let colors: [Color]; let at: Date }
    private static var cache: [String: Entry] = [:]

    /// 某个文件的颜色标签色点（最多 3 个，和访达一样叠在名字旁边）。
    /// 结果缓存 10 秒：在访达里改了标签，分区下次刷新时就能看到；不会每次重画都去读磁盘。
    static func dotColors(for url: URL) -> [Color] {
        let key = url.path
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 10 { return hit.colors }
        let names = tagNames(of: url)
        var colors: [Color] = []
        if !names.isEmpty {
            let labels = NSWorkspace.shared.fileLabels
            for name in names {
                if let index = labels.firstIndex(of: name), index > 0 {
                    colors.append(Color(nsColor: color(for: index)))
                }
                if colors.count == 3 { break }
            }
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = Entry(colors: colors, at: Date())
        return colors
    }

    static func invalidate(_ url: URL) { cache[url.path] = nil }
}

/// 名字旁边的颜色标签色点（叠在一起的小圆点，带一圈细描边，深浅背景都看得清）。
struct TagDots: View {
    let colors: [Color]

    var body: some View {
        if !colors.isEmpty {
            HStack(spacing: -3) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                        .frame(width: 8, height: 8)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)
        }
    }
}

/// 右键菜单里那一排颜色圆点（访达同款）：点一下切换标签；已有的标签中间带勾，鼠标移上去放大。
final class TagSwatchMenuView: NSView {
    private let indices = FinderTags.menuOrder
    private var applied: Set<Int>
    private var hovered: Int?
    private let onToggle: (Int) -> Void
    private let diameter: CGFloat = 14
    private let spacing: CGFloat = 10
    private let leftInset: CGFloat = 14
    private var tracking: NSTrackingArea?

    init(applied: Set<Int>, onToggle: @escaping (Int) -> Void) {
        self.applied = applied
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 14 * 2 + 7 * 14 + 6 * 10, height: 26))
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("颜色标签", "Tags"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rect(at i: Int) -> NSRect {
        NSRect(x: leftInset + CGFloat(i) * (diameter + spacing), y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func index(at point: NSPoint) -> Int? {
        indices.indices.first { rect(at: $0).insetBy(dx: -4, dy: -5).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hovered { hovered = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onToggle(indices[i])
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, label) in indices.enumerated() {
            var r = rect(at: i)
            if hovered == i { r = r.insetBy(dx: -2, dy: -2) }
            let path = NSBezierPath(ovalIn: r)
            FinderTags.color(for: label).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            if applied.contains(label) {
                // 已有这个标签：中间一个白色小勾
                let check = NSBezierPath()
                check.move(to: NSPoint(x: r.minX + r.width * 0.28, y: r.midY))
                check.line(to: NSPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.32))
                check.line(to: NSPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.70))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        indices.enumerated().map { i, label in
            let element = NSAccessibilityElement.element(
                withRole: .button,
                frame: NSAccessibility.screenRect(fromView: self, rect: rect(at: i)),
                label: FinderTags.name(for: label) ?? "",
                parent: self
            ) as! NSAccessibilityElement
            return element
        }
    }
}

/// 子进程错误输出的收集器（后台线程写、完成后读），只留前 8KB。
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < 8192 else { return }
        data.append(chunk.prefix(8192 - data.count))
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
