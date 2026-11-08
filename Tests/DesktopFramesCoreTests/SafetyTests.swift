import Darwin
import Foundation
import Testing
@testable import DesktopFramesCore

/// v2 安全审查修复的回归测试。
@Suite("安全：不丢文件、不打开非本地 URL")
struct SafetyTests {

    private func makeSandbox() throws -> (src: URL, dst: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafetyTests-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("来源", isDirectory: true)
        let dst = root.appendingPathComponent("分区文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        return (src, dst)
    }

    private func write(_ name: String, in dir: URL, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    @Test("把已在分区文件夹里的文件“替换”进同一文件夹：什么都不做，文件还在")
    func replaceIntoSameFolderIsNoop() throws {
        let (_, dst) = try makeSandbox()
        let file = try write("报告.txt", in: dst, "原内容")
        let result = try FileOperationService().moveDetailed(item: file, into: dst, policy: .replace)
        #expect(result.outcome == .cancelled)
        #expect(try String(contentsOf: file, encoding: .utf8) == "原内容")
    }

    @Test("替换：旧文件进废纸篓而不是永久删除；撤销后两者都回到原位")
    func replaceTrashesAndUndoRestores() throws {
        let (src, dst) = try makeSandbox()
        let incoming = try write("同名.txt", in: src, "新")
        let existing = try write("同名.txt", in: dst, "旧")
        let service = FileOperationService()

        let result = try service.moveDetailed(item: incoming, into: dst, policy: .replace)
        guard case .moved(let destination) = result.outcome else {
            Issue.record("应已移动"); return
        }
        let trashed = try #require(result.replacedTrashURL)
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "新")

        try service.undo(MoveUndoRecord(source: incoming, destination: destination, replacedTrashURL: trashed))
        #expect(try String(contentsOf: incoming, encoding: .utf8) == "新")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "旧")
    }

    @Test("布局里非本地文件 URL 的条目被丢弃，其它条目和分区保留")
    func nonFileURLItemsDropped() throws {
        let json = """
        {"version":1,"zones":[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"测","kind":"virtual",
        "frame":{"x":0,"y":0,"width":300,"height":200},"screenID":"1",
        "appearance":{"tint":"white","opacity":0.9,"collapsed":false},
        "items":[{"url":"https://evil.example/Applications","kind":"folder"},
                 {"url":"file:///Applications/","kind":"folder"}]}]}
        """
        let doc = try JSONDecoder().decode(LayoutDocument.self, from: Data(json.utf8))
        #expect(doc.zones.count == 1)
        #expect(doc.zones[0].items.count == 1)
        #expect(doc.zones[0].items[0].url.isFileURL)
    }

    @Test("备份节流：间隔内多次保存只产生一份备份")
    func backupThrottle() throws {
        let (_, dir) = try makeSandbox()
        let store = ZoneStore(layoutFile: dir.appendingPathComponent("layout.json"))
        store.minimumBackupInterval = 600
        for i in 0..<6 {
            try store.save(LayoutDocument(zones: [Zone(
                name: "第\(i)", kind: .virtual,
                frame: ZoneFrame(x: 0, y: 0, width: 300, height: 200), screenID: "1"
            )]))
        }
        #expect(store.availableBackups().count == 1)
    }

    @Test("清理未完成临时副本：里面有只读文件夹和锁定文件也能删干净；不带前缀的绝不碰")
    func removePartialHandlesLockedContents() throws {
        let (_, dst) = try makeSandbox()
        let partial = dst.appendingPathComponent("\(FileOperationService.partialPrefix)TEST")
        let sub = partial.appendingPathComponent("只读", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let locked = try write("锁定.txt", in: sub, "x")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chmod(sub.path, 0o555) == 0)
        FileOperationService.removePartial(partial)
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        let userFile = try write("用户文件.txt", in: dst, "保留")
        FileOperationService.removePartial(userFile)
        #expect(FileManager.default.fileExists(atPath: userFile.path))
    }
}
