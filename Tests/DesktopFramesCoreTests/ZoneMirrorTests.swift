import Foundation
import Testing
@testable import DesktopFramesCore

/// 「Tuck 分区」入口文件夹：只建 / 删 Tuck 自己的链接，原文件和用户自己的东西绝不碰。
@Suite("Tuck 分区入口文件夹")
struct ZoneMirrorTests {

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoneMirrorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func file(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("原件".utf8).write(to: url)
        return url
    }

    private func zone(_ name: String, kind: ZoneKind = .virtual, items: [URL] = [], folder: String? = nil) -> Zone {
        var z = Zone(name: name, kind: kind, frame: ZoneFrame(), screenID: "1", backingFolderPath: folder)
        z.items = items.map { ZoneItem(url: $0, kind: .file) }
        return z
    }

    @Test("按分区建子文件夹和链接；链接指向原文件，原文件不动")
    func buildsLinks() throws {
        let base = try sandbox()
        let desk = base.appendingPathComponent("desk", isDirectory: true)
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        let a = try file("报告.pdf", in: desk)
        let mirror = ZoneMirror(root: base.appendingPathComponent("Tuck 分区"))
        mirror.sync(ZoneMirror.plan(for: [zone("工作", items: [a])]))
        let link = mirror.root.appendingPathComponent("工作/报告.pdf").path
        #expect(ZoneMirror.isSymlink(link))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == a.path)
        #expect(try String(contentsOfFile: link, encoding: .utf8) == "原件")
        #expect(!ZoneMirror.isSymlink(a.path))
    }

    @Test("项目移出分区 / 分区删除：链接和空的 Tuck 子文件夹被拿掉，原文件还在")
    func removesStale() throws {
        let base = try sandbox()
        let a = try file("a.txt", in: base), b = try file("b.txt", in: base)
        let mirror = ZoneMirror(root: base.appendingPathComponent("M"))
        mirror.sync(ZoneMirror.plan(for: [zone("一", items: [a, b]), zone("二", items: [a])]))
        mirror.sync(ZoneMirror.plan(for: [zone("一", items: [a])]))
        let fm = FileManager.default
        #expect(try fm.contentsOfDirectory(atPath: mirror.root.appendingPathComponent("一").path) == ["a.txt"])
        #expect(!fm.fileExists(atPath: mirror.root.appendingPathComponent("二").path))
        #expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path))
    }

    @Test("用户自己放进来的真文件 / 同名文件夹绝不碰")
    func leavesUserFilesAlone() throws {
        let base = try sandbox()
        let a = try file("a.txt", in: base)
        let mirror = ZoneMirror(root: base.appendingPathComponent("M"))
        try FileManager.default.createDirectory(at: mirror.root, withIntermediateDirectories: true)
        let mine = try file("我的笔记.txt", in: mirror.root)
        let userFolder = mirror.root.appendingPathComponent("工作", isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let inside = try file("草稿.txt", in: userFolder)
        mirror.sync(ZoneMirror.plan(for: [zone("工作", items: [a])]))
        mirror.sync([])
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: mine.path))
        #expect(fm.fileExists(atPath: inside.path))
        #expect(!ZoneMirror.isSymlink(userFolder.appendingPathComponent("a.txt").path)) // 没往用户文件夹里塞链接
    }

    @Test("文件分区直接链接到关联文件夹；同名分区和同名文件自动编号；名字里的 / 和开头的点被处理")
    func namingAndFolderZones() throws {
        let base = try sandbox()
        let d1 = base.appendingPathComponent("d1", isDirectory: true), d2 = base.appendingPathComponent("d2", isDirectory: true)
        try FileManager.default.createDirectory(at: d1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: true)
        let x1 = try file("x.txt", in: d1), x2 = try file("x.txt", in: d2)
        let plan = ZoneMirror.plan(for: [
            zone("资料", items: [x1, x2]), zone("资料"), zone(".隐/藏"),
            zone("项目", kind: .folder, folder: d1.path)
        ])
        #expect(plan.map(\.name) == ["资料", "资料 2", "隐-藏", "项目"])
        let mirror = ZoneMirror(root: base.appendingPathComponent("M"))
        mirror.sync(plan)
        let names = try FileManager.default.contentsOfDirectory(atPath: mirror.root.appendingPathComponent("资料").path).sorted()
        #expect(names == ["x 2.txt", "x.txt"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mirror.root.appendingPathComponent("项目").path) == d1.path)
    }

    @Test("用户自己做的链接、不是 Tuck 建的非空同名文件夹都不碰；原文件不会被打标记")
    func leavesUserLinksAndForeignRootAlone() throws {
        let base = try sandbox()
        let a = try file("a.txt", in: base)
        let mirror = ZoneMirror(root: base.appendingPathComponent("M"))
        mirror.sync(ZoneMirror.plan(for: [zone("一", items: [a])]))
        let userLink = mirror.root.appendingPathComponent("我的链接").path
        try FileManager.default.createSymbolicLink(atPath: userLink, withDestinationPath: a.path)
        mirror.sync([])
        #expect(ZoneMirror.isSymlink(userLink))
        #expect(!ZoneMirror.hasMark(a.path))

        let foreign = ZoneMirror(root: base.appendingPathComponent("F"))
        try FileManager.default.createDirectory(at: foreign.root, withIntermediateDirectories: true)
        _ = try file("已有.txt", in: foreign.root)
        foreign.sync(ZoneMirror.plan(for: [zone("一", items: [a])]))
        #expect(!FileManager.default.fileExists(atPath: foreign.root.appendingPathComponent("一").path))
    }
}
