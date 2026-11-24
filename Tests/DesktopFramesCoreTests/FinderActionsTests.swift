import CoreGraphics
import Foundation
import Testing
@testable import DesktopFramesCore

/// 访达同款操作的核心逻辑：复制的命名、复制不覆盖、改名后入口跟着走、复制结果紧挨原项目、撤销记录兼容旧存档。
@Suite("访达同款操作")
struct FinderActionsTests {

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderActionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ name: String, in dir: URL, content: String = "数据") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    @Test("复制命名：名字 副本.扩展名，再复制往后编号，不叠“副本 副本”")
    func duplicateNames() throws {
        let dir = try sandbox()
        let service = FileOperationService()
        let file = try write("报告.pdf", in: dir)
        let first = service.duplicateDestination(for: file, copyWord: "副本")
        #expect(first.lastPathComponent == "报告 副本.pdf")
        _ = try service.duplicate(item: file, to: first)
        let second = service.duplicateDestination(for: file, copyWord: "副本")
        #expect(second.lastPathComponent == "报告 副本 2.pdf")
        // 对“副本”再复制：接着编号
        let third = service.duplicateDestination(for: first, copyWord: "副本")
        #expect(third.lastPathComponent == "报告 副本 2.pdf")
    }

    @Test("复制命名：文件夹名字里的点不当扩展名")
    func duplicateFolderWithDot() throws {
        let dir = try sandbox()
        let folder = dir.appendingPathComponent("v1.2 资料", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = FileOperationService().duplicateDestination(for: folder, copyWord: "副本")
        #expect(dest.lastPathComponent == "v1.2 资料 副本")
    }

    @Test("复制：内容一致、原文件不动、目标已存在时绝不覆盖")
    func duplicateNeverOverwrites() throws {
        let dir = try sandbox()
        let service = FileOperationService()
        let file = try write("a.txt", in: dir, content: "原件")
        let taken = try write("a 副本.txt", in: dir, content: "别人的")
        #expect(throws: (any Error).self) { try service.duplicate(item: file, to: taken) }
        #expect(try String(contentsOf: taken, encoding: .utf8) == "别人的")
        let dest = service.duplicateDestination(for: file, copyWord: "副本")
        let made = try service.duplicate(item: file, to: dest)
        #expect(try String(contentsOf: made, encoding: .utf8) == "原件")
        #expect(try String(contentsOf: file, encoding: .utf8) == "原件")
        // 不留临时文件
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(FileOperationService.partialPrefix) }
        #expect(leftovers.isEmpty)
    }

    @MainActor
    private func makeModel() throws -> AppModel {
        let root = try sandbox()
        let store = ZoneStore(layoutFile: root.appendingPathComponent("layout.json"), backupsDirectory: root.appendingPathComponent("Backups"))
        let screens = [ScreenDescriptor(displayID: 1, name: "主显示器", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))]
        return AppModel(store: store, screens: screens)
    }

    @MainActor
    @Test("改名：所有分区里指向旧路径的入口改指新路径，位置不变")
    func retargetKeepsPosition() throws {
        let model = try makeModel()
        let dir = try sandbox()
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt"), c = dir.appendingPathComponent("c.txt")
        let z1 = model.createZone(kind: .virtual, name: "一", frame: ZoneFrame(), screenID: "1", backingFolderPath: nil)
        let z2 = model.createZone(kind: .virtual, name: "二", frame: ZoneFrame(), screenID: "1", backingFolderPath: nil)
        model.addItem(ZoneItem(url: a, kind: .file), to: z1.id)
        model.addItem(ZoneItem(url: b, kind: .file, displayName: "旧显示名"), to: z1.id)
        model.addItem(ZoneItem(url: c, kind: .file), to: z1.id)
        model.addItem(ZoneItem(url: b, kind: .file), to: z2.id)
        let renamed = dir.appendingPathComponent("新名字.txt")
        #expect(model.retargetEntries(from: b, to: renamed) == 2)
        let items = try #require(model.zone(id: z1.id)?.items)
        #expect(items.map(\.url.lastPathComponent) == ["a.txt", "新名字.txt", "c.txt"])
        #expect(items[1].displayName == nil)
        #expect(model.zone(id: z2.id)?.items.first?.url == renamed)
    }

    @MainActor
    @Test("插入：紧挨在原项目后面；找不到原项目就放最后；同一文件不重复")
    func insertAfterAnchor() throws {
        let model = try makeModel()
        let dir = try sandbox()
        let zone = model.createZone(kind: .virtual, name: "插入", frame: ZoneFrame(), screenID: "1", backingFolderPath: nil)
        let a = ZoneItem(url: dir.appendingPathComponent("a.txt"), kind: .file)
        let b = ZoneItem(url: dir.appendingPathComponent("b.txt"), kind: .file)
        model.addItem(a, to: zone.id)
        model.addItem(b, to: zone.id)
        let copy = ZoneItem(url: dir.appendingPathComponent("a 副本.txt"), kind: .file)
        #expect(model.insertItem(copy, after: a.id, in: zone.id))
        #expect(!model.insertItem(copy, after: a.id, in: zone.id))
        let tail = ZoneItem(url: dir.appendingPathComponent("z.zip"), kind: .file)
        #expect(model.insertItem(tail, after: UUID(), in: zone.id))
        #expect(model.zone(id: zone.id)?.items.map(\.url.lastPathComponent) == ["a.txt", "a 副本.txt", "b.txt", "z.zip"])
    }

    @Test("撤销记录：带回原分区的 ID 能存能读；旧存档没有这个字段也照常读")
    func undoRecordCoding() throws {
        let zoneID = UUID()
        let record = MoveUndoRecord(source: URL(fileURLWithPath: "/tmp/a.txt"), destination: URL(fileURLWithPath: "/tmp/.Trash/a.txt"), restoreZoneID: zoneID)
        let decoded = try JSONDecoder().decode(MoveUndoRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.restoreZoneID == zoneID)
        let legacy = #"{"source":"file:///tmp/a.txt","destination":"file:///tmp/b.txt"}"#
        let old = try JSONDecoder().decode(MoveUndoRecord.self, from: Data(legacy.utf8))
        #expect(old.restoreZoneID == nil)
    }
}
