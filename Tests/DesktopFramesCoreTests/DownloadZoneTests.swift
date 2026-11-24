import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("下载直接进分区")
struct DownloadZoneTests {

    @Test("下载中的临时文件和隐藏文件不算")
    func ignorable() {
        for name in ["报告.pdf.crdownload", "Unconfirmed 123.crdownload", "视频.mp4.download", "a.zip.part", ".DS_Store", "x.opdownload", "Icon\r"] {
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

    @Test("原有的桌面文件永远不收；新下载要连续两次大小不变才收")
    func collector() {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: ["旧文件.pdf", "截图.png"])
        // 原有文件即使带新的下载标记也不收
        #expect(c.step([.init(name: "旧文件.pdf", size: 10, downloadedAt: now)], now: now, webOnly: true).isEmpty)
        // 下载中：临时名字不收
        #expect(c.step([.init(name: "新.pdf.crdownload", size: 5, downloadedAt: now)], now: now, webOnly: true).isEmpty)
        // 改成正式名字：第一次看到先等
        #expect(c.step([.init(name: "新.pdf", size: 100, downloadedAt: now)], now: now, webOnly: true).isEmpty)
        #expect(c.hasPending)
        // 还在变大：继续等
        #expect(c.step([.init(name: "新.pdf", size: 120, downloadedAt: now)], now: now, webOnly: true).isEmpty)
        // 大小稳定：收
        #expect(c.step([.init(name: "新.pdf", size: 120, downloadedAt: now)], now: now, webOnly: true) == ["新.pdf"])
        #expect(!c.hasPending)
        // 收过的不再收
        #expect(c.step([.init(name: "新.pdf", size: 120, downloadedAt: now)], now: now, webOnly: true).isEmpty)
    }

    @Test("只收网页下载时：没有下载标记、或很久以前下的，不收")
    func webOnly() {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: [])
        let entries: [DesktopDownloadCollector.Entry] = [
            .init(name: "截屏.png", size: 1, downloadedAt: nil),
            .init(name: "老下载.zip", size: 1, downloadedAt: now.addingTimeInterval(-86400)),
        ]
        #expect(c.step(entries, now: now, webOnly: true).isEmpty)
        #expect(c.step(entries, now: now, webOnly: true).isEmpty)
        // 关掉“只收网页下载”：新出现的截图会收
        var all = DesktopDownloadCollector(baseline: [])
        let shot = [DesktopDownloadCollector.Entry(name: "截屏.png", size: 1, downloadedAt: nil)]
        #expect(all.step(shot, now: now, webOnly: false).isEmpty)
        #expect(all.step(shot, now: now, webOnly: false) == ["截屏.png"])
    }

    @Test("被删掉后同名再下载一次，还会收")
    func redownload() {
        let now = Date()
        var c = DesktopDownloadCollector(baseline: [])
        let e = DesktopDownloadCollector.Entry(name: "a.pdf", size: 3, downloadedAt: now)
        _ = c.step([e], now: now, webOnly: true)
        #expect(c.step([e], now: now, webOnly: true) == ["a.pdf"])
        _ = c.step([], now: now, webOnly: true)
        _ = c.step([e], now: now, webOnly: true)
        #expect(c.step([e], now: now, webOnly: true) == ["a.pdf"])
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
            let entries = files.map { DesktopDownloadCollector.Entry(name: $0.0, size: $0.1, downloadedAt: now) }
            got += c.step(entries, now: now, webOnly: true)
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
