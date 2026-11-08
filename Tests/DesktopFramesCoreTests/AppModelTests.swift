import CoreGraphics
import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("AppModel 启动清洗与落盘")
struct AppModelTests {

    private func makeTempStore() throws -> (root: URL, store: ZoneStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ZoneStore(
            layoutFile: root.appendingPathComponent("layout.json"),
            backupsDirectory: root.appendingPathComponent("Backups")
        )
        return (root, store)
    }

    private func screens() -> [ScreenDescriptor] {
        [
            ScreenDescriptor(
                displayID: 1,
                name: "主显示器",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
            )
        ]
    }


    /// 等待条件成立（防抖落盘是异步的，避免固定时长造成的偶发失败）。
    /// @MainActor：条件闭包在主线程求值（store.load 无 actor 隔离，此处一致即可）。
    @MainActor
    private func waitUntil(timeout: Double = 3.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    @MainActor
    @Test("无布局文件时从空文档启动，不产生额外文件")
    func startsEmptyWithoutFile() async throws {
        let (root, store) = try makeTempStore()
        let model = AppModel(store: store, screens: screens())
        #expect(model.document.zones.isEmpty)
        // 空启动不应立即落盘
        #expect(!FileManager.default.fileExists(atPath: store.layoutFile.path))
        _ = root
    }

    @MainActor
    @Test("记录的屏幕缺失：启动清洗把分区回收主屏并落盘")
    func missingScreenMigratesToPrimaryAndSaves() async throws {
        let (_, store) = try makeTempStore()
        // 手工写一个记录在外接屏(屏幕 2)上的分区
        let zone = Zone(
            name: "旧屏分区",
            kind: .virtual,
            frame: ZoneFrame(x: 3000, y: -800, width: 420, height: 300),
            screenID: "2"
        )
        try store.save(LayoutDocument(zones: [zone]))

        let model = AppModel(store: store, screens: screens())
        let saved = try #require(model.document.zones.first)
        #expect(saved.screenID == "1")
        let visible = screens()[0].visibleFrame
        #expect(saved.frame.x >= Double(visible.minX + FrameSanitizer.margin) - 0.001)
        #expect(saved.frame.x + saved.frame.width <= Double(visible.maxX - FrameSanitizer.margin) + 0.001)

        // 清洗结果已落盘（防抖是异步的，轮询等待）
        await waitUntil { store.load().document.zones.first?.screenID == "1" }
        #expect(store.load().document.zones.first?.screenID == "1")
    }

    @MainActor
    @Test("创建分区后防抖持久化")
    func createZonePersistsAfterDebounce() async throws {
        let (_, store) = try makeTempStore()
        let model = AppModel(store: store, screens: screens())
        model.createZone(
            kind: .virtual,
            name: "测试分区",
            frame: ZoneFrame(x: 100, y: 100, width: 420, height: 300),
            screenID: "1",
            backingFolderPath: nil
        )
        #expect(model.document.zones.count == 1)
        // 等待防抖落盘
        await waitUntil { store.load().document.zones.count == 1 }
        let reloaded = store.load().document
        #expect(reloaded.zones.count == 1)
        #expect(reloaded.zones.first?.name == "测试分区")
    }

    @MainActor
    @Test("连续移动只写一次（防抖合并）")
    func rapidFrameUpdatesCoalesce() async throws {
        let (_, store) = try makeTempStore()
        let model = AppModel(store: store, screens: screens())
        model.createZone(
            kind: .virtual,
            name: "分区",
            frame: ZoneFrame(x: 0, y: 0, width: 420, height: 300),
            screenID: "1",
            backingFolderPath: nil
        )
        for i in 1...20 {
            model.updateFrame(
                zoneID: try #require(model.document.zones.first?.id),
                rect: CGRect(x: CGFloat(i) * 5, y: 100, width: 420, height: 300),
                screenID: "1"
            )
        }
        // 等待最终落盘，再断言合并结果
        await waitUntil { store.load().document.zones.first?.frame.x == 100.0 }
        let reloaded = store.load().document
        let savedX = try #require(reloaded.zones.first?.frame.x)
        #expect(savedX == 100.0, "最终位置应持久化，实际 \(savedX)")
        // 主布局文件应只有最新状态一份；防抖合并后至多一份备份
        let backups = store.availableBackups()
        #expect(backups.count <= 1)
    }

    @MainActor
    @Test("清理失效条目：文件消失且父目录存在才移除；父目录不在则保留")
    func purgeMissingEntriesBehavior() async throws {
        let (_, store) = try makeTempStore()
        let model = AppModel(store: store, screens: screens())

        // 建一个临时目录放两个文件
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PurgeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let aURL = parent.appendingPathComponent("a.txt")
        let bURL = parent.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: aURL)
        try Data("b".utf8).write(to: bURL)

        let zone = model.createZone(
            kind: .virtual,
            name: "清理测试",
            frame: ZoneFrame(x: 0, y: 0, width: 420, height: 300),
            screenID: "1",
            backingFolderPath: nil
        )
        model.addItem(ZoneItem(url: aURL, kind: .file), to: zone.id)   // 仍存在 → 保留
        model.addItem(ZoneItem(url: bURL, kind: .file), to: zone.id)   // 将被删除 → 清理
        // 模拟文件被删除/移走
        try FileManager.default.removeItem(at: bURL)

        let removed = model.purgeMissingEntries()
        #expect(removed == 1)
        let remaining = try #require(model.document.zones.first?.items)
        #expect(remaining.count == 1)
        #expect(remaining.first?.url == aURL)

        // 父目录也消失（外接卷卸载等）→ 条目保留，避免误删
        let ghostParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostParent-\(UUID().uuidString)", isDirectory: true)
        let ghostFile = ghostParent.appendingPathComponent("g.txt")
        model.addItem(ZoneItem(url: ghostFile, kind: .file), to: zone.id)
        let removed2 = model.purgeMissingEntries()
        #expect(removed2 == 0)
        #expect(try #require(model.document.zones.first?.items).count == 2)
        try? FileManager.default.removeItem(at: parent)
    }

    @MainActor
    @Test("退出归位候选：只含文件分区内真实移入关联文件夹的条目")
    func restoreCandidatesOnlyFromFolderZones() throws {
        let (_, store) = try makeTempStore()
        let model = AppModel(store: store, screens: screens())

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreCandidates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let desktop = tmp.appendingPathComponent("Desktop", isDirectory: true) // 仅作比较用的“桌面”
        let backing = tmp.appendingPathComponent("backing", isDirectory: true)
        try FileManager.default.createDirectory(at: backing, withIntermediateDirectories: true)
        let inBacking = backing.appendingPathComponent("拖入.txt")
        let alsoOnDesktop = desktop.appendingPathComponent("本就在桌面.txt")
        let outside = tmp.appendingPathComponent("别处.txt")

        // 文件分区：条目位于关联文件夹内 → 候选
        let folderZone = model.createZone(
            kind: .folder, name: "文件框", frame: ZoneFrame(),
            screenID: "1", backingFolderPath: backing.path
        )
        model.addItem(ZoneItem(url: inBacking, kind: .file), to: folderZone.id)
        // 关联文件夹就是桌面根目录的分区 → 跳过
        let desktopZone = model.createZone(
            kind: .folder, name: "桌面框", frame: ZoneFrame(),
            screenID: "1", backingFolderPath: desktop.path
        )
        model.addItem(ZoneItem(url: alsoOnDesktop, kind: .file), to: desktopZone.id)
        // 文件分区里指向别处的条目（异常数据）→ 跳过
        model.addItem(ZoneItem(url: outside, kind: .file), to: folderZone.id)
        // 虚拟分区：从不移动文件 → 跳过
        let virtualZone = model.createZone(
            kind: .virtual, name: "虚拟", frame: ZoneFrame(),
            screenID: "1", backingFolderPath: nil
        )
        model.addItem(ZoneItem(url: alsoOnDesktop, kind: .file), to: virtualZone.id)

        let candidates = model.itemsMovedIntoZoneFolders(desktopURL: desktop)
        #expect(candidates.count == 1)
        #expect(candidates.first?.zoneID == folderZone.id)
        #expect(candidates.first?.item.url == inBacking)
        try? FileManager.default.removeItem(at: tmp)
    }

    @MainActor
    @Test("movedFrom 原位置随布局持久化往返")
    func movedFromRoundTrip() throws {
        let (root, store) = try makeTempStore()
        let model = AppModel(store: store, screens: screens())
        let backing = root.appendingPathComponent("back", isDirectory: true)
        try FileManager.default.createDirectory(at: backing, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("原位置", isDirectory: true).appendingPathComponent("a.txt")
        let zone = model.createZone(
            kind: .folder, name: "框", frame: ZoneFrame(),
            screenID: "1", backingFolderPath: backing.path
        )
        model.addItem(
            ZoneItem(url: backing.appendingPathComponent("a.txt"), kind: .file, movedFrom: original),
            to: zone.id
        )
        model.persistNow()

        let reloaded = try #require(
            ZoneStore(layoutFile: store.layoutFile, backupsDirectory: root.appendingPathComponent("B2"))
                .load().document.zones.first?.items.first
        )
        #expect(reloaded.movedFrom == original)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("拖动排序：按给定顺序重排，缺的项目排在后面，未知 ID 忽略")
    @MainActor
    func reorderItems() throws {
        let (_, store) = try makeTempStore()
        let model = AppModel(store: store, screens: screens())
        let zone = model.createZone(
            kind: .virtual,
            name: "排序测试",
            frame: ZoneFrame(x: 0, y: 0, width: 420, height: 300),
            screenID: "1",
            backingFolderPath: nil
        )
        let items = ["a", "b", "c", "d"].map {
            ZoneItem(url: URL(fileURLWithPath: "/tmp/reorder-\($0)"), kind: .file)
        }
        for item in items { model.addItem(item, to: zone.id) }
        let (a, b, c, d) = (items[0].id, items[1].id, items[2].id, items[3].id)

        model.reorderItems(zoneID: zone.id, orderedIDs: [c, a, UUID(), b])
        #expect(model.zone(id: zone.id)?.items.map(\.id) == [c, a, b, d])

        model.reorderItems(zoneID: zone.id, orderedIDs: [d, d, c])
        #expect(model.zone(id: zone.id)?.items.map(\.id) == [d, c, a, b])
    }
}

