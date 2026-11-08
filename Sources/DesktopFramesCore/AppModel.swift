import Combine
import Foundation

/// 退出自动归位的候选：文件分区中被真实移入关联文件夹的一个条目（含所在分区 id）。
public struct MovedItemCandidate: Equatable, Sendable {
    public let zoneID: UUID
    public let item: ZoneItem

    public init(zoneID: UUID, item: ZoneItem) {
        self.zoneID = zoneID
        self.item = item
    }
}

/// 应用模型：持有布局文档，所有修改都经此类并触发防抖持久化。
/// 无 AppKit 依赖（UI 无关），以便单测覆盖启动清洗与落盘逻辑。
/// 全部方法应在主线程（@MainActor）调用。
@MainActor
public final class AppModel: ObservableObject {
    public let store: ZoneStore

    @Published public private(set) var document: LayoutDocument
    /// 启动时若发生损坏恢复 / 布局清洗，提示用户。
    @Published public private(set) var notice: String?

    private var saveWork: Task<Void, Never>?

    public init(store: ZoneStore, screens: [ScreenDescriptor]) {
        self.store = store
        let loaded = store.load()
        var doc = loaded.document
        var layoutChanged = false

        // 启动坐标清洗：把每个分区按记录的屏幕恢复；屏幕缺失则回收主屏；越界则夹取。
        if !screens.isEmpty {
            for i in doc.zones.indices {
                let zone = doc.zones[i]
                let result = FrameSanitizer.restoreZone(
                    frame: FrameSanitizer.cgRect(from: zone.frame),
                    screenID: zone.screenID,
                    screens: screens
                )
                let rect = result.frame
                let chosenID = screens[result.screenIndex].displayID
                if FrameSanitizer.cgRect(from: zone.frame) != rect
                    || FrameSanitizer.parseScreenID(zone.screenID) != chosenID {
                    doc.zones[i].frame = FrameSanitizer.zoneFrame(from: rect)
                    doc.zones[i].screenID = "\(chosenID)"
                    doc.zones[i].updatedAt = Date()
                    layoutChanged = true
                }
            }
        }

        document = doc
        notice = loaded.notice

        // 损坏恢复或坐标清洗后立刻落盘一次，保证后续启动稳定。
        if loaded.recoveredFromCorruption || layoutChanged {
            do {
                try store.save(doc)
            } catch {
                notice = (notice ?? "") + " 首次保存失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 查询

    public func zone(id: UUID) -> Zone? {
        document.zones.first { $0.id == id }
    }

    // MARK: - 分区操作

    @discardableResult
    public func createZone(
        kind: ZoneKind,
        name: String,
        frame: ZoneFrame,
        screenID: String,
        backingFolderPath: String?
    ) -> Zone {
        let zone = Zone(
            name: name,
            kind: kind,
            frame: frame,
            screenID: screenID,
            backingFolderPath: backingFolderPath
        )
        document.zones.append(zone)
        persist()
        return zone
    }

    public func deleteZone(id: UUID) {
        document.zones.removeAll { $0.id == id }
        persist()
    }

    public func renameZone(id: UUID, name: String) {
        guard let i = index(of: id) else { return }
        document.zones[i].name = name
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 锁定/解锁分区位置（锁定后窗口不可拖动/缩放）。
    public func setLocked(zoneID: UUID, locked: Bool) {
        guard let i = index(of: zoneID) else { return }
        document.zones[i].locked = locked
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 设置分区玻璃密度（0.10–1.0，两步取整避免 JSON 噪声）。越接近 0.10 越通透。
    public func setOpacity(zoneID: UUID, opacity: Double) {
        guard let i = index(of: zoneID) else { return }
        let value = (opacity * 100).rounded() / 100
        document.zones[i].appearance.opacity = min(max(value, 0.10), 1.0)
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 设置分区主题色（tint 标识字符串，如 "systemBlue"）。
    public func setTint(zoneID: UUID, tint: String) {
        guard let i = index(of: zoneID) else { return }
        document.zones[i].appearance.tint = tint
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 切换分区内容显示方式（列表 / 图标）。
    public func setViewMode(zoneID: UUID, mode: ZoneViewMode) {
        guard let i = index(of: zoneID) else { return }
        document.zones[i].viewMode = mode
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 折叠 / 展开分区（折叠时窗口只保留标题条；zone.frame 始终保存展开尺寸）。
    public func setCollapsed(zoneID: UUID, collapsed: Bool) {
        guard let i = index(of: zoneID) else { return }
        document.zones[i].appearance.collapsed = collapsed
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 用户拖动 / 缩放窗口后回写几何。
    public func updateFrame(zoneID: UUID, rect: CGRect, screenID: String) {
        guard let i = index(of: zoneID) else { return }
        document.zones[i].frame = FrameSanitizer.zoneFrame(from: rect)
        document.zones[i].screenID = screenID
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 屏幕变更后回写分区所在屏幕（几何不变）。
    public func updateScreenID(zoneID: UUID, screenID: String) {
        guard let i = index(of: zoneID) else { return }
        document.zones[i].screenID = screenID
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 从备份整体替换布局。
    public func replace(document newDocument: LayoutDocument) {
        document = newDocument
        persist()
    }

    // MARK: - 分区条目操作

    /// 向分区追加条目；同一 URL 已存在时跳过（防止重复入口）。
    /// - Returns: 是否真的新增。
    @discardableResult
    public func addItem(_ item: ZoneItem, to zoneID: UUID) -> Bool {
        guard let i = index(of: zoneID) else { return false }
        let exists = document.zones[i].items.contains { $0.url.standardizedFileURL == item.url.standardizedFileURL }
        guard !exists else { return false }
        document.zones[i].items.append(item)
        document.zones[i].updatedAt = Date()
        persist()
        return true
    }

    /// 调整分区里项目的顺序（拖动排序）。orderedIDs 里没有的项目按原相对顺序排在后面，
    /// orderedIDs 里已不存在的 ID 忽略；顺序没变就什么都不做。
    public func reorderItems(zoneID: UUID, orderedIDs: [UUID]) {
        guard let i = index(of: zoneID) else { return }
        let items = document.zones[i].items
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        var result: [ZoneItem] = []
        for id in orderedIDs where !seen.contains(id) {
            if let item = byID[id] { result.append(item); seen.insert(id) }
        }
        result.append(contentsOf: items.filter { !seen.contains($0.id) })
        guard result.map(\.id) != items.map(\.id) else { return }
        document.zones[i].items = result
        document.zones[i].updatedAt = Date()
        persist()
    }

    public func removeItem(id: UUID, from zoneID: UUID) {
        guard let i = index(of: zoneID) else { return }
        document.zones[i].items.removeAll { $0.id == id }
        document.zones[i].updatedAt = Date()
        persist()
    }

    /// 从所有分区移除指向该 URL 的条目（真实移动撤销后调用，把回到原位的项目移出分区列表）。
    public func removeEntries(pointingTo url: URL) {
        let target = url.standardizedFileURL
        var changed = false
        for i in document.zones.indices {
            let before = document.zones[i].items.count
            document.zones[i].items.removeAll { $0.url.standardizedFileURL == target }
            if document.zones[i].items.count != before {
                document.zones[i].updatedAt = Date()
                changed = true
            }
        }
        if changed { persist() }
    }

    /// 清理失效条目：文件已不在且其父目录仍存在（如被拖出/移动/删除）→ 移除该入口。
    /// 父目录也不存在（如外接卷未挂载）时保留条目，避免误删。
    /// - Returns: 清理掉的条目数。
    @discardableResult
    public func purgeMissingEntries() -> Int {
        let fm = FileManager.default
        var removed = 0
        for i in document.zones.indices {
            let zone = document.zones[i]
            var kept: [ZoneItem] = []
            kept.reserveCapacity(zone.items.count)
            for item in zone.items {
                let url = item.url
                if !fm.fileExists(atPath: url.path),
                   fm.fileExists(atPath: url.deletingLastPathComponent().path) {
                    removed += 1
                } else {
                    kept.append(item)
                }
            }
            if kept.count != zone.items.count {
                document.zones[i].items = kept
                document.zones[i].updatedAt = Date()
            }
        }
        if removed > 0 { persist() }
        return removed
    }

    // MARK: - 撤销记录

    public var undoBatch: [MoveUndoRecord] {
        document.lastMoveUndo ?? []
    }

    public func setUndoBatch(_ records: [MoveUndoRecord]?) {
        document.lastMoveUndo = records
        persist()
    }

    public func clearUndo() {
        document.lastMoveUndo = nil
        persist()
    }

    /// 退出自动归位的候选条目：只包含“文件分区中被真实移动进关联文件夹”的项目
    /// （虚拟/应用分区从不移动源文件，不在此列；关联文件夹本身就是桌面根目录时跳过）。
    /// 归位动作（真实移动 + 冲突策略）由 App 层执行，此处只做纯计算，便于单测。
    public func itemsMovedIntoZoneFolders(desktopURL: URL) -> [MovedItemCandidate] {
        let desk = desktopURL.standardizedFileURL
        var result: [MovedItemCandidate] = []
        for zone in document.zones where zone.kind == .folder {
            guard let backing = zone.backingFolderURL else { continue }
            let backingStandard = backing.standardizedFileURL
            guard backingStandard != desk else { continue } // 框就是桌面，无需归位
            for item in zone.items
            where item.url.deletingLastPathComponent().standardizedFileURL == backingStandard {
                result.append(MovedItemCandidate(zoneID: zone.id, item: item))
            }
        }
        return result
    }

    // MARK: - 持久化

    /// 立即落盘（取消挂起的防抖任务）。
    public func persistNow() {
        saveWork?.cancel()
        saveNow()
    }

    private func index(of id: UUID) -> Int? {
        document.zones.firstIndex { $0.id == id }
    }

    /// 防抖保存：连续拖动窗口时合并写盘。
    private func persist() {
        saveWork?.cancel()
        saveWork = Task { [weak self] in
            // 被取消（又有新变更）时不落盘
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        do {
            try store.save(document)
        } catch {
            notice = "保存布局失败：\(error.localizedDescription)"
        }
    }
}
