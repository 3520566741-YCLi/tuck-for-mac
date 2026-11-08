import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("FileOperationService 真实移动")
struct FileOperationServiceTests {

    private func makeSandbox() throws -> (root: URL, sourceDir: URL, targetDir: URL, service: FileOperationService) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOpsTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("来源", isDirectory: true)
        let targetDir = root.appendingPathComponent("分区文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        return (root, sourceDir, targetDir, FileOperationService())
    }

    private func write(_ name: String, in dir: URL, content: String = "数据") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("无冲突移动：源消失、目标出现")
    func plainMove() throws {
        let (_, src, dst, service) = try makeSandbox()
        let item = try write("报告.pdf", in: src)
        let outcome = try service.move(item: item, into: dst, policy: .cancel)
        guard case .moved(let dest) = outcome else {
            Issue.record("应成功移动")
            return
        }
        #expect(dest == dst.appendingPathComponent("报告.pdf"))
        #expect(!exists(item))
        #expect(exists(dest))
    }

    @Test("移动文件夹（含递归内容）")
    func moveFolder() throws {
        let (_, src, dst, service) = try makeSandbox()
        let folder = src.appendingPathComponent("课程", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("笔记.md", in: folder)
        let outcome = try service.move(item: folder, into: dst, policy: .cancel)
        guard case .moved(let dest) = outcome else {
            Issue.record("应成功移动")
            return
        }
        #expect(exists(dest.appendingPathComponent("笔记.md")))
        #expect(!exists(folder))
    }

    @Test("同名冲突 + 取消：双方原样保留（默认行为）")
    func conflictCancelKeepsBothSides() throws {
        let (_, src, dst, service) = try makeSandbox()
        let item = try write("a.txt", in: src, content: "新文件")
        let existing = try write("a.txt", in: dst, content: "旧文件")

        let outcome = try service.move(item: item, into: dst, policy: .cancel)
        #expect(outcome == .cancelled)
        #expect(exists(item))
        #expect(exists(existing))
        let kept = try String(contentsOf: existing, encoding: .utf8)
        #expect(kept == "旧文件")
    }

    @Test("同名冲突 + 保留两者：生成不冲突新名字，旧文件不动")
    func conflictKeepBoth() throws {
        let (_, src, dst, service) = try makeSandbox()
        let item = try write("a.txt", in: src, content: "新文件")
        _ = try write("a.txt", in: dst, content: "旧文件")

        let outcome = try service.move(item: item, into: dst, policy: .keepBoth)
        guard case .moved(let dest) = outcome else {
            Issue.record("应移动")
            return
        }
        #expect(dest.lastPathComponent == "a 2.txt")
        #expect(!exists(item))
        #expect(exists(dst.appendingPathComponent("a.txt")))
        let content = try String(contentsOf: dest, encoding: .utf8)
        #expect(content == "新文件")
    }

    @Test("同名冲突 + 替换：旧文件被覆盖，源消失")
    func conflictReplace() throws {
        let (_, src, dst, service) = try makeSandbox()
        let item = try write("a.txt", in: src, content: "新文件")
        _ = try write("a.txt", in: dst, content: "旧文件")

        let outcome = try service.move(item: item, into: dst, policy: .replace)
        guard case .moved(let dest) = outcome else {
            Issue.record("应移动")
            return
        }
        #expect(dest == dst.appendingPathComponent("a.txt"))
        #expect(!exists(item))
        let content = try String(contentsOf: dest, encoding: .utf8)
        #expect(content == "新文件")
    }

    @Test("uniqueDestination 递增到不冲突的名字")
    func uniqueDestinationSkipsTakenNames() throws {
        let (_, _, dst, service) = try makeSandbox()
        _ = try write("b.txt", in: dst)
        _ = try write("b 2.txt", in: dst)
        let item = dst.appendingPathComponent("b.txt")
        let unique = service.uniqueDestination(for: item, in: dst)
        #expect(unique.lastPathComponent == "b 3.txt")
    }

    @Test("源缺失 / 目标文件夹缺失时报错")
    func missingPathsThrow() throws {
        let (_, src, dst, service) = try makeSandbox()
        let ghost = src.appendingPathComponent("不存在.txt")
        #expect(throws: FileOperationError.sourceMissing) {
            _ = try service.move(item: ghost, into: dst, policy: .cancel)
        }
        let real = try write("x.txt", in: src)
        let ghostDir = src.appendingPathComponent("没有这个目录", isDirectory: true)
        #expect(throws: FileOperationError.folderMissing) {
            _ = try service.move(item: real, into: ghostDir, policy: .cancel)
        }
    }

    @Test("撤销：项目回到原位置，目标消失")
    func undoRestores() throws {
        let (_, src, dst, service) = try makeSandbox()
        let item = try write("a.txt", in: src)
        guard case .moved(let dest) = try service.move(item: item, into: dst, policy: .cancel) else {
            Issue.record("应移动")
            return
        }
        let record = MoveUndoRecord(source: item, destination: dest)
        try service.undo(record)
        #expect(exists(item))
        #expect(!exists(dest))
    }

    @Test("撤销时原位置被占用则拒绝覆盖")
    func undoRefusesWhenOccupied() throws {
        let (_, src, dst, service) = try makeSandbox()
        let item = try write("a.txt", in: src)
        guard case .moved(let dest) = try service.move(item: item, into: dst, policy: .cancel) else {
            Issue.record("应移动")
            return
        }
        // 有人在原位置放了新文件
        _ = try write("a.txt", in: src, content: "新来的")
        let record = MoveUndoRecord(source: item, destination: dest)
        #expect(throws: FileOperationError.occupied(item)) {
            try service.undo(record)
        }
        // 新来的没被动过
        let content = try String(contentsOf: item, encoding: .utf8)
        #expect(content == "新来的")
    }

    @Test("撤销时目标已消失则报错")
    func undoWhenDestinationGone() throws {
        let (_, src, dst, service) = try makeSandbox()
        let item = try write("a.txt", in: src)
        guard case .moved(let dest) = try service.move(item: item, into: dst, policy: .cancel) else {
            Issue.record("应移动")
            return
        }
        try FileManager.default.removeItem(at: dest)
        let record = MoveUndoRecord(source: item, destination: dest)
        #expect(throws: FileOperationError.itemGone(dest)) {
            try service.undo(record)
        }
    }

    @Test("批撤记录：整批移动可整体撤销")
    func batchUndo() throws {
        let (_, src, dst, service) = try makeSandbox()
        var records: [MoveUndoRecord] = []
        for name in ["c1.txt", "c2.txt", "c3.txt"] {
            let item = try write(name, in: src)
            guard case .moved(let dest) = try service.move(item: item, into: dst, policy: .cancel) else {
                Issue.record("应移动")
                return
            }
            records.append(MoveUndoRecord(source: item, destination: dest))
        }
        #expect(records.count == 3)
        for record in records {
            try service.undo(record)
            #expect(exists(record.source))
            #expect(!exists(record.destination))
        }
    }

    @Test("文件种类判定")
    func typeInspector() throws {
        let (_, src, _, _) = try makeSandbox()
        let file = try write("照片.png", in: src)
        #expect(FileTypeInspector.kind(of: file) == .file)

        let folder = src.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FileTypeInspector.kind(of: folder) == .folder)

        let app = src.appendingPathComponent("预览.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(FileTypeInspector.kind(of: app) == .application)
    }

    @Test("moveBack：精确回到原位置，源消失目标出现")
    func moveBackToOriginal() throws {
        let (root, src, dst, service) = try makeSandbox()
        let original = try write("报告.pdf", in: src)
        // 模拟拖入分区文件夹
        let outcome = try service.move(item: original, into: dst, policy: .cancel)
        guard case .moved(let current) = outcome else {
            Issue.record("应移动成功")
            return
        }
        // 放回桌面原位置
        let back = try service.moveBack(item: current, toOriginal: original)
        #expect(back == .moved(destination: original))
        #expect(exists(original))
        #expect(!exists(current))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("moveBack：原位置被占用时不覆盖，返回 cancelled")
    func moveBackOccupiedKeepsBoth() throws {
        let (root, src, dst, service) = try makeSandbox()
        let original = try write("a.txt", in: src, content: "最初")
        let outcome = try service.move(item: original, into: dst, policy: .cancel)
        guard case .moved(let current) = outcome else {
            Issue.record("应移动成功")
            return
        }
        try write("a.txt", in: src, content: "后来者") // 原位置被占用
        let back = try service.moveBack(item: current, toOriginal: original)
        #expect(back == .cancelled)
        #expect(exists(current)) // 分区里的文件保留
        let content = try String(contentsOf: original, encoding: .utf8)
        #expect(content == "后来者") // 原位置文件未被覆盖
        try? FileManager.default.removeItem(at: root)
    }

    @Test("moveBack：原目录不存在时抛 folderMissing")
    func moveBackParentMissing() throws {
        let (root, src, dst, service) = try makeSandbox()
        let item = try write("a.txt", in: src)
        let outcome = try service.move(item: item, into: dst, policy: .cancel)
        guard case .moved(let current) = outcome else {
            Issue.record("应移动成功")
            return
        }
        let ghostOriginal = root.appendingPathComponent("已删除目录").appendingPathComponent("a.txt")
        #expect(throws: FileOperationError.folderMissing) {
            _ = try service.moveBack(item: current, toOriginal: ghostOriginal)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 复制（⌥ 拖放）

    @Test("复制：源保留、目标出现、内容相同")
    func plainCopy() throws {
        let (root, src, dst, service) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try write("表格.xlsx", in: src, content: "内容A")
        let r = try service.copyDetailed(item: item, into: dst, policy: .cancel)
        guard case .moved(let dest) = r.outcome else { Issue.record("应成功复制"); return }
        #expect(exists(item))
        #expect(try String(contentsOf: dest, encoding: .utf8) == "内容A")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dst.path)
            .filter { $0.hasPrefix(FileOperationService.partialPrefix) }
        #expect(leftovers.isEmpty)
    }

    @Test("复制到同一文件夹：自动另起名字，不覆盖")
    func copyIntoSameFolder() throws {
        let (root, src, _, service) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try write("笔记.txt", in: src)
        let r = try service.copyDetailed(item: item, into: src, policy: .cancel)
        guard case .moved(let dest) = r.outcome else { Issue.record("应生成副本"); return }
        #expect(dest.lastPathComponent == "笔记 2.txt")
        #expect(exists(item))
    }

    @Test("复制冲突默认取消，目标原文件不变")
    func copyConflictCancel() throws {
        let (root, src, dst, service) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try write("a.txt", in: src, content: "新")
        let old = try write("a.txt", in: dst, content: "旧")
        let r = try service.copyDetailed(item: item, into: dst, policy: .cancel)
        #expect(r.outcome == .cancelled)
        #expect(try String(contentsOf: old, encoding: .utf8) == "旧")
    }

    @Test("文件夹不能复制进自己里面")
    func copyIntoItself() throws {
        let (root, src, _, service) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = src.appendingPathComponent("父", isDirectory: true)
        let child = folder.appendingPathComponent("子", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        #expect(throws: FileOperationError.self) {
            _ = try service.copyDetailed(item: folder, into: child, policy: .cancel)
        }
    }
}
