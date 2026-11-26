import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("下载直接进分区")
struct DownloadZoneTests {

    @Test("下载中的临时文件和隐藏文件不算")
    func ignorable() {
        for name in ["~$报告.docx", "报告.pdf.crdownload", "Unconfirmed 123.crdownload", "视频.mp4.download", "a.zip.part", ".DS_Store", "x.opdownload", "Icon\r"] {
            #expect(DownloadFiles.isIgnorable(name: name), "\(name)")
        }
        for name in ["报告.pdf", "下载.zip", "partner.docx", "Download Guide.pdf"] {
            #expect(!DownloadFiles.isIgnorable(name: name), "\(name)")
        }
    }

    @Test("读隔离标记里的下载时间")
    func quarantine() {
        let d = DownloadFiles.parseQuarantine("0083;6743a1b2;Safari;5D3C2E8F-0000")
        #expect(d == Date(timeIntervalSince1970: TimeInterval(0x6743a1b2)))
        #expect(DownloadFiles.parseQuarantine("garbage") == nil)
        #expect(DownloadFiles.parseQuarantine("0083;zz;Safari;") == nil)
    }

    private func names(_ r: [DesktopDownloadCollector.Ready]) -> [String] { r.map(\.name) }

    @Test("原有的文件永远不收；新文件要连续两次大小不变才收")
    func collector() {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: ["旧文件.pdf", "截图.png"])
        #expect(c.step([.init(name: "旧文件.pdf", size: 10, createdAt: now)], now: now, includeScreenshots: false).isEmpty)
        #expect(c.step([.init(name: "新.pdf.crdownload", size: 5, createdAt: now)], now: now, includeScreenshots: false).isEmpty)
        #expect(c.step([.init(name: "新.pdf", size: 100, createdAt: now)], now: now, includeScreenshots: false).isEmpty)
        #expect(c.hasPending)
        #expect(c.step([.init(name: "新.pdf", size: 120, createdAt: now)], now: now, includeScreenshots: false).isEmpty)
        #expect(names(c.step([.init(name: "新.pdf", size: 120, createdAt: now)], now: now, includeScreenshots: false)) == ["新.pdf"])
        #expect(!c.hasPending)
        #expect(c.step([.init(name: "新.pdf", size: 120, createdAt: now)], now: now, includeScreenshots: false).isEmpty)
    }

    @Test("另存为 / 别的软件保存（没有下载标记）也收；老文件挪进来不收；Office 锁文件不收")
    func anySave() {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: [])
        let entries: [DesktopDownloadCollector.Entry] = [
            .init(name: "网页图片.jpg", size: 2000, createdAt: now.addingTimeInterval(-3)),
            .init(name: "去年的表.xlsx", size: 900, createdAt: now.addingTimeInterval(-86400)),
            .init(name: "~$报告.docx", size: 162, createdAt: now),
        ]
        #expect(c.step(entries, now: now, includeScreenshots: false).isEmpty)
        #expect(names(c.step(entries, now: now, includeScreenshots: false)) == ["网页图片.jpg"])
    }

    @Test("正被软件打开着（还在写）的先不收，关了再收")
    func inUse() {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: [])
        let open = DesktopDownloadCollector.Entry(name: "导出.mov", size: 5000, createdAt: now, inUse: true)
        #expect(c.step([open], now: now, includeScreenshots: false).isEmpty)
        #expect(c.step([open], now: now, includeScreenshots: false).isEmpty)
        #expect(c.hasPending)
        let closed = DesktopDownloadCollector.Entry(name: "导出.mov", size: 5000, createdAt: now)
        #expect(c.step([closed], now: now, includeScreenshots: false).isEmpty)
        #expect(names(c.step([closed], now: now, includeScreenshots: false)) == ["导出.mov"])
    }

    @Test("截图默认不收；勾上「截图也收」才收，并标明是截图")
    func screenshots() {
        let now = Date()
        let shot = DesktopDownloadCollector.Entry(name: "截屏2026-11-26 10.00.00.png", size: 1, createdAt: now, isScreenshot: true)
        var off = DesktopDownloadCollector(baseline: [])
        #expect(off.step([shot], now: now, includeScreenshots: false).isEmpty)
        #expect(off.step([shot], now: now, includeScreenshots: false).isEmpty)
        var on = DesktopDownloadCollector(baseline: [])
        #expect(on.step([shot], now: now, includeScreenshots: true).isEmpty)
        #expect(on.step([shot], now: now, includeScreenshots: true) == [.init(name: shot.name, isScreenshot: true)])
    }

    @Test("被删掉后同名再存一次，还会收")
    func redownload() {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: [])
        let e = DesktopDownloadCollector.Entry(name: "a.pdf", size: 3, createdAt: now)
        _ = c.step([e], now: now, includeScreenshots: false)
        #expect(names(c.step([e], now: now, includeScreenshots: false)) == ["a.pdf"])
        _ = c.step([], now: now, includeScreenshots: false)
        _ = c.step([e], now: now, includeScreenshots: false)
        #expect(names(c.step([e], now: now, includeScreenshots: false)) == ["a.pdf"])
    }

    @Test("下载分区：自动列出的入口不写进布局，只存真实移动进来的；退出归位不碰下载的文件")
    @MainActor
    func liveFolderPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveFolder-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("下载", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ZoneStore(layoutFile: root.appendingPathComponent("layout.json"), backupsDirectory: root.appendingPathComponent("Backups"))
        let model = AppModel(store: store, screens: [])
        let zone = model.createZone(kind: .folder, name: "下载", frame: ZoneFrame(), screenID: "1", backingFolderPath: folder.path, liveFolder: true)
        #expect(model.zone(id: zone.id)?.liveFolder == true)
        #expect(model.zone(id: zone.id)?.sortOrder == .dateAdded)

        let a = folder.appendingPathComponent("a.pdf"), b = folder.appendingPathComponent("b.zip")
        #expect(model.syncLiveFolder(zoneID: zone.id, entries: [(a, false), (b, false)]) == 2)
        #expect(model.syncLiveFolder(zoneID: zone.id, entries: [(a, false), (b, false)]) == 0) // 不重复
        // 从桌面拖进来的（真实移动，带原位置）
        var moved = ZoneItem(url: folder.appendingPathComponent("c.key"), kind: .file, movedFrom: root.appendingPathComponent("Desktop/c.key"))
        moved.movedFileNumber = 1
        model.addItem(moved, to: zone.id)

        // 退出归位：只认拖进来的那个
        let candidates = model.itemsMovedIntoZoneFolders(desktopURL: root.appendingPathComponent("Desktop"))
        #expect(candidates.map(\.item.url.lastPathComponent) == ["c.key"])

        model.persistNow()
        let saved = store.load().document.zones.first { $0.id == zone.id }
        #expect(saved?.liveFolder == true)
        #expect(saved?.items.map(\.url.lastPathComponent) == ["c.key"])

        // 普通文件分区不受影响（不写 liveFolder 字段）
        let plain = Zone(name: "x", kind: .folder, backingFolderPath: folder.path)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("liveFolder"))
    }

    @Test("入口文件夹：下载分区的真文件夹不再建链接，名字也让出来；建文件夹不打 Tuck 标记")
    func mirrorPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorDL-\(UUID().uuidString)/Tuck 分区", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let mirror = ZoneMirror(root: root)
        let folder = try #require(mirror.makeDownloadFolder(named: "下载"))
        #expect(folder.lastPathComponent == "下载")
        #expect(!ZoneMirror.hasMark(folder.path))
        #expect(ZoneMirror.hasMark(root.path))
        // 再建一次同名：用户已有的普通文件夹直接用
        #expect(mirror.makeDownloadFolder(named: "下载") == folder)

        let live = Zone(name: "下载", kind: .folder, backingFolderPath: folder.path, liveFolder: true)
        let other = Zone(name: "下载", kind: .virtual)
        let plan = ZoneMirror.plan(for: [live, other], root: root)
        #expect(plan.count == 1)
        if case .folder(let name, _) = plan[0] { #expect(name == "下载 2") } else { Issue.record("应该是子文件夹") }

        // 同步不会删掉 / 改动下载文件夹和里面的文件
        try Data("x".utf8).write(to: folder.appendingPathComponent("真文件.pdf"))
        mirror.sync(plan)
        mirror.sync([])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("真文件.pdf").path))
    }

    @Test("同名普通分区的入口子文件夹只有 Tuck 链接时接过来用；里面有用户真文件就不用它")
    func reuseMirrorFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorReuse-\(UUID().uuidString)/Tuck 分区", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let mirror = ZoneMirror(root: root)
        let target = root.deletingLastPathComponent().appendingPathComponent("原文件.pdf")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target)
        mirror.sync([.folder(name: "下载", targets: [target]), .folder(name: "素材", targets: [])])
        let reused = try #require(mirror.makeDownloadFolder(named: "下载"))
        #expect(reused.lastPathComponent == "下载")
        #expect(!ZoneMirror.hasMark(reused.path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: reused.path)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path)) // 原文件没动

        try Data("y".utf8).write(to: root.appendingPathComponent("素材/用户的.txt"))
        let other = try #require(mirror.makeDownloadFolder(named: "素材"))
        #expect(other.lastPathComponent == "素材 2")
    }

    /// 按各浏览器真实的下载过程走一遍：下载途中一个都不收，下完只收正式文件一次。
    private func simulate(_ steps: [[(String, Int64)]]) -> [String] {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: [])
        var got: [String] = []
        for files in steps {
            let entries = files.map { DesktopDownloadCollector.Entry(name: $0.0, size: $0.1, createdAt: now) }
            got += c.step(entries, now: now, includeScreenshots: false).map(\.name)
        }
        return got
    }

    @Test("Chrome / Edge / Arc / Brave：Unconfirmed.crdownload → 名字.crdownload → 名字")
    func chromium() {
        let got = simulate([
            [("Unconfirmed 12345.crdownload", 100)],
            [("模型.3mf.crdownload", 5000)],
            [("模型.3mf.crdownload", 9000)],
            [("模型.3mf", 9000)],
            [("模型.3mf", 9000)],
        ])
        #expect(got == ["模型.3mf"])
    }

    @Test("Firefox：先放一个正式名字的空文件 + 名字.part，下完把 .part 改成正式名字")
    func firefox() {
        let got = simulate([
            [("报告.pdf", 0), ("报告.pdf.part", 1000)],
            [("报告.pdf", 0), ("报告.pdf.part", 4000)],
            [("报告.pdf", 0), ("报告.pdf.part", 8000)],
            [("报告.pdf", 8000)],
            [("报告.pdf", 8000)],
        ])
        #expect(got == ["报告.pdf"])
    }

    @Test("Safari：名字.download 包 → 名字；Opera：名字.opdownload → 名字")
    func safariOpera() {
        #expect(simulate([[("a.zip.download", 64)], [("a.zip.download", 64)], [("a.zip", 300)], [("a.zip", 300)]]) == ["a.zip"])
        #expect(simulate([[("b.dmg.opdownload", 10)], [("b.dmg", 20)], [("b.dmg", 20)]]) == ["b.dmg"])
    }
}
