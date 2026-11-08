import Foundation
import Testing
@testable import DesktopFramesCore

/// 每个测试使用独立临时目录，避免并行执行相互干扰。
private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZoneStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeStore(in root: URL) -> ZoneStore {
    ZoneStore(
        layoutFile: root.appendingPathComponent("layout.json"),
        backupsDirectory: root.appendingPathComponent("Backups")
    )
}

private func sampleZone(name: String = "课程学习", kind: ZoneKind = .virtual) -> Zone {
    Zone(
        name: name,
        kind: kind,
        frame: ZoneFrame(x: 10, y: 20, width: 420, height: 300),
        screenID: "display-1",
        backingFolderPath: kind == .folder ? "/tmp/some-backing" : nil,
        items: [ZoneItem(url: URL(fileURLWithPath: "/tmp/a.pdf"), kind: .file, displayName: "a.pdf")]
    )
}

@Suite("ZoneStore 布局存储")
struct ZoneStoreTests {

    @Test("无文件时返回空文档")
    func emptyWhenNoFile() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)
        let result = store.load()
        #expect(result.document.zones.isEmpty)
        #expect(!result.recoveredFromCorruption)
        #expect(result.notice == nil)
    }

    @Test("保存后再加载，字段完整往返")
    func roundTrip() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)

        // 用整秒时间，保证 iso8601 往返无损。
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        var zone = sampleZone()
        zone.createdAt = fixed
        zone.updatedAt = fixed

        var doc = LayoutDocument(zones: [zone])
        let undo = MoveUndoRecord(
            source: URL(fileURLWithPath: "/tmp/src/a.pdf"),
            destination: URL(fileURLWithPath: "/tmp/dst/a.pdf"),
            performedAt: fixed
        )
        doc.lastMoveUndo = [undo]

        try store.save(doc)

        let result = store.load()
        #expect(!result.recoveredFromCorruption)
        let loaded = result.document
        #expect(loaded.zones.count == 1)
        #expect(loaded.zones[0] == zone)
        #expect(loaded.lastMoveUndo == [undo])
    }

    @Test("旧版单条撤销记录自动包装为数组")
    func singleUndoRecordMigratesToBatch() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)
        let legacy = """
        {"version":1,"zones":[],"lastMoveUndo":{"id":"11111111-2222-3333-4444-555555555555",
        "source":"file:///tmp/a.pdf","destination":"file:///tmp/b.pdf"}}
        """
        try Data(legacy.utf8).write(to: store.layoutFile)
        let result = store.load()
        let batch = try #require(result.document.lastMoveUndo)
        #expect(batch.count == 1)
        #expect(batch[0].source.lastPathComponent == "a.pdf")
    }

    @Test("每次保存滚动备份，只保留最近五份")
    func backupRotationKeepsFive() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)

        for i in 0..<8 {
            var doc = LayoutDocument(zones: [sampleZone(name: "第\(i)个")])
            if i == 7 {
                doc.zones[0].name = "最新状态"
            }
            try store.save(doc)
        }

        let backups = store.availableBackups()
        #expect(backups.count == 5, "应只保留 5 份备份，实际 \(backups.count)")

        // 最新备份内容应对应第 7 次写入前的状态（第 6 次写入的内容）。
        let newest = try store.restoreBackup(try #require(backups.first))
        #expect(newest.zones.first?.name == "第6个")
    }

    @Test("损坏的 JSON 被隔离，返回空文档并保留损坏文件")
    func corruptFileQuarantined() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)

        // 先写入一个合法布局，再破坏它，验证备份路径与隔离路径都存在。
        try store.save(LayoutDocument(zones: [sampleZone(name: "原始")]))
        try Data("这不是 JSON{{{".utf8).write(to: store.layoutFile)

        let result = store.load()
        #expect(result.recoveredFromCorruption)
        #expect(result.document.zones.isEmpty)
        let quarantine = try #require(result.quarantinedFile)
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        // 主文件已不在原位（被隔离改名）。
        #expect(!FileManager.default.fileExists(atPath: store.layoutFile.path))

        // 隔离后可以正常保存并重新加载。
        try store.save(LayoutDocument(zones: [sampleZone(name: "重建")]))
        let reloaded = store.load()
        #expect(reloaded.document.zones.first?.name == "重建")
    }

    @Test("空文件按损坏处理")
    func emptyFileQuarantined() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)
        try Data().write(to: store.layoutFile)

        let result = store.load()
        #expect(result.recoveredFromCorruption)
        #expect(result.quarantinedFile != nil)
    }

    @Test("更新版本的布局：不破坏原文件，存档后从空布局开始")
    func futureVersionPreserved() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)

        let futureJSON = """
        {"version": 99, "zones": [{"name": "未来分区"}]}
        """
        try Data(futureJSON.utf8).write(to: store.layoutFile)

        let result = store.load()
        #expect(result.document.zones.isEmpty)
        #expect(result.notice != nil)
        // 原文件仍保留在主位置（未被删除或改名）。
        #expect(FileManager.default.fileExists(atPath: store.layoutFile.path))
        // 存档文件存在。
        let archives = try FileManager.default
            .contentsOfDirectory(atPath: store.backupsDirectory.path)
            .filter { $0.hasPrefix("layout-future-") }
        #expect(!archives.isEmpty)
    }

    @Test("恢复备份返回对应文档并写回主文件")
    func restoreBackupWorks() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)

        // 第一次保存：无先前文件，不产生备份
        try store.save(LayoutDocument(zones: [sampleZone(name: "一期")]))
        // 第二次保存：备份一份(一期)，主文件=二期
        try store.save(LayoutDocument(zones: [sampleZone(name: "二期")]))
        // 第三次保存：备份两份(一期、二期)，主文件=三期
        try store.save(LayoutDocument(zones: [sampleZone(name: "三期")]))

        let all = store.availableBackups()
        #expect(all.count == 2)
        #expect(all.first?.url.lastPathComponent != all.last?.url.lastPathComponent)

        let oldest = try #require(all.last) // 最旧备份 = 一期
        let restored = try store.restoreBackup(oldest)
        #expect(restored.zones.first?.name == "一期")

        let main = store.load().document
        #expect(main.zones.first?.name == "一期")
    }

    @Test("手工编写的早期 v0 布局（缺字段）也能解析并补默认值")
    func v0HandWrittenLayoutParses() throws {
        let root = try makeTempDirectory()
        let store = makeStore(in: root)

        let handWritten = """
        {
          "zones": [
            {
              "id": "3D2E1B1C-8A5F-4C4E-9B2A-1C2D3E4F5A6B",
              "name": "课程学习",
              "kind": "folder",
              "frame": {"x": 0, "y": 0, "width": 420, "height": 300},
              "screenID": "display-1",
              "appearance": {"tint": "systemBlue", "opacity": 0.82, "collapsed": false},
              "tabs": [],
              "items": []
            }
          ]
        }
        """
        try Data(handWritten.utf8).write(to: store.layoutFile)

        let result = store.load()
        #expect(!result.recoveredFromCorruption)
        let zone = try #require(result.document.zones.first)
        #expect(zone.name == "课程学习")
        #expect(zone.kind == .folder)
        #expect(zone.frame.width == 420)
        #expect(zone.items.isEmpty)
        #expect(zone.createdAt.timeIntervalSince1970 > 0)
    }
}
