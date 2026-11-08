import Darwin
import Foundation
import Testing
@testable import DesktopFramesCore

@Suite("桌面原图标隐藏：只动自己隐藏的、可恢复")
struct DesktopHidingTests {
    private func makeDesktop() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopHidingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ name: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    @Test("隐藏后再恢复：文件原地不动、内容不变")
    func hideThenRestore() throws {
        let desk = try makeDesktop()
        let a = try touch("a.txt", in: desk)
        let hider = DesktopHider(desktop: desk)
        let tracked = hider.reconcile(wanted: [a], tracked: [])
        #expect(tracked == [a])
        #expect(DesktopHider.isHidden(URL(fileURLWithPath: a)))
        let after = hider.restoreAll(tracked: tracked)
        #expect(after.isEmpty)
        #expect(!DesktopHider.isHidden(URL(fileURLWithPath: a)))
        #expect(try String(contentsOfFile: a, encoding: .utf8) == "x")
    }

    @Test("用户原本就隐藏的文件：不记成我们的，恢复时也不取消隐藏")
    func neverUnhideUserHidden() throws {
        let desk = try makeDesktop()
        let mine = try touch("用户隐藏.txt", in: desk)
        #expect(chflags(mine, UInt32(UF_HIDDEN)) == 0)
        let hider = DesktopHider(desktop: desk)
        let tracked = hider.reconcile(wanted: [mine], tracked: [])
        #expect(tracked.isEmpty)
        _ = hider.restoreAll(tracked: tracked)
        #expect(DesktopHider.isHidden(URL(fileURLWithPath: mine)))
    }

    @Test("只处理桌面直属项目：子文件夹里的、别处的文件不隐藏")
    func onlyDirectChildren() throws {
        let desk = try makeDesktop()
        let sub = desk.appendingPathComponent("子文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = try touch("里面.txt", in: sub)
        let elsewhere = try touch("别处.txt", in: try makeDesktop())
        let tracked = DesktopHider(desktop: desk).reconcile(wanted: [nested, elsewhere], tracked: [])
        #expect(tracked.isEmpty)
        #expect(!DesktopHider.isHidden(URL(fileURLWithPath: nested)))
        #expect(!DesktopHider.isHidden(URL(fileURLWithPath: elsewhere)))
    }

    @Test("从分区移除：只恢复这一个，其它仍隐藏")
    func removeOneRestoresOnlyIt() throws {
        let desk = try makeDesktop()
        let a = try touch("a.txt", in: desk), b = try touch("b.txt", in: desk)
        let hider = DesktopHider(desktop: desk)
        var tracked = hider.reconcile(wanted: [a, b], tracked: [])
        tracked = hider.reconcile(wanted: [b], tracked: tracked)
        #expect(tracked == [b])
        #expect(!DesktopHider.isHidden(URL(fileURLWithPath: a)))
        #expect(DesktopHider.isHidden(URL(fileURLWithPath: b)))
    }

    @Test("崩溃后重启：记录持久化，重新对账能把状态恢复一致")
    func registrySurvivesRestart() throws {
        let desk = try makeDesktop()
        let a = try touch("a.txt", in: desk)
        let regFile = desk.appendingPathComponent("../reg-\(UUID().uuidString).json").standardizedFileURL
        let reg = HiddenRegistry(file: regFile)
        let hider = DesktopHider(desktop: desk)
        reg.update(hider.reconcile(wanted: [a], tracked: reg.paths) { reg.update($0) })
        // 模拟崩溃：不调用 restoreAll，直接用新实例读取记录
        let reloaded = HiddenRegistry(file: regFile)
        #expect(reloaded.paths == [a])
        reloaded.update(hider.restoreAll(tracked: reloaded.paths))
        #expect(!DesktopHider.isHidden(URL(fileURLWithPath: a)))
        #expect(HiddenRegistry(file: regFile).paths.isEmpty)
    }

    @Test("文件已不在：记录作废，不报错")
    func missingFileDropsRecord() throws {
        let desk = try makeDesktop()
        let ghost = desk.appendingPathComponent("不存在.txt").path
        let tracked = DesktopHider(desktop: desk).reconcile(wanted: [], tracked: [ghost])
        #expect(tracked.isEmpty)
    }

    @Test("被隐藏的文件被别的程序移出桌面：用书签找到新位置并恢复显示")
    func movedAwayFileGetsUnhidden() throws {
        let desk = try makeDesktop()
        let other = try makeDesktop()
        let a = try touch("会被移走.txt", in: desk)
        let reg = HiddenRegistry(file: other.appendingPathComponent("reg.json"))
        let hider = DesktopHider(desktop: desk)
        reg.update(hider.reconcile(wanted: [a], tracked: reg.paths) { reg.update($0) } relocate: { reg.locate($0) } isOriginal: { reg.isOriginal($0) })
        #expect(DesktopHider.isHidden(URL(fileURLWithPath: a)))

        let moved = other.appendingPathComponent("会被移走.txt")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: a), to: moved)
        #expect(DesktopHider.isHidden(moved)) // 隐藏标记跟着文件走了

        // 重新读取记录（模拟重启），对账
        let reloaded = HiddenRegistry(file: other.appendingPathComponent("reg.json"))
        let left = hider.reconcile(wanted: [], tracked: reloaded.paths) { reloaded.update($0) } relocate: { reloaded.locate($0) } isOriginal: { reloaded.isOriginal($0) }
        reloaded.update(left)
        #expect(left.isEmpty)
        #expect(!DesktopHider.isHidden(moved))
    }

    @Test("旧格式记录（只有路径）可以读取")
    func legacyRegistryFormat() throws {
        let dir = try makeDesktop()
        let file = dir.appendingPathComponent("reg.json")
        try JSONEncoder().encode(["/Users/x/Desktop/a.txt"]).write(to: file)
        #expect(HiddenRegistry(file: file).paths == ["/Users/x/Desktop/a.txt"])
    }

    @Test("原路径换成了另一个同名文件（用户自己隐藏的）：不取消它的隐藏")
    func replacedFileKeepsUserHidden() throws {
        let desk = try makeDesktop()
        let a = try touch("同名.txt", in: desk)
        let reg = HiddenRegistry(file: try makeDesktop().appendingPathComponent("reg.json"))
        let hider = DesktopHider(desktop: desk)
        reg.update(hider.reconcile(wanted: [a], tracked: reg.paths) { reg.update($0) } relocate: { reg.locate($0) } isOriginal: { reg.isOriginal($0) })
        try FileManager.default.removeItem(atPath: a)          // 测试临时文件
        _ = try touch("同名.txt", in: desk)                     // 新文件，不同 inode
        #expect(chflags(a, UInt32(UF_HIDDEN)) == 0) // 用户自己用访达 / chflags 隐藏（不带 Tuck 标记）
        let left = hider.reconcile(wanted: [], tracked: reg.paths) { reg.update($0) } relocate: { reg.locate($0) } isOriginal: { reg.isOriginal($0) }
        #expect(left.isEmpty)
        #expect(DesktopHider.isHidden(URL(fileURLWithPath: a)))
    }

    @Test("编辑器安全保存（换了 inode、带着 Tuck 标记）：移出分区时仍能恢复显示")
    func safeSaveStillUnhidden() throws {
        let desk = try makeDesktop()
        let a = try touch("文档.txt", in: desk)
        let reg = HiddenRegistry(file: try makeDesktop().appendingPathComponent("reg.json"))
        let hider = DesktopHider(desktop: desk)
        reg.update(hider.reconcile(wanted: [a], tracked: reg.paths) { reg.update($0) } relocate: { reg.locate($0) } isOriginal: { reg.isOriginal($0) })
        // 模拟安全保存：复制出新文件（带扩展属性和标记）再替换原文件 → inode 改变
        let tmp = desk.appendingPathComponent(".文档.tmp")
        try FileManager.default.copyItem(atPath: a, toPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: a), withItemAt: tmp)
        #expect(!reg.isOriginal(a))
        let left = hider.reconcile(wanted: [], tracked: reg.paths) { reg.update($0) } relocate: { reg.locate($0) } isOriginal: { reg.isOriginal($0) }
        #expect(left.isEmpty)
        #expect(!DesktopHider.isHidden(URL(fileURLWithPath: a)))
        #expect(!DesktopHider.hasTuckMark(URL(fileURLWithPath: a)))
    }

    @Test("记录里混入非桌面路径（被篡改）：作废，不去动它")
    func nonDesktopRecordIgnored() throws {
        let desk = try makeDesktop()
        let other = try touch("别处.txt", in: try makeDesktop())
        #expect(chflags(other, UInt32(UF_HIDDEN)) == 0)
        let left = DesktopHider(desktop: desk).reconcile(wanted: [], tracked: [other])
        #expect(left.isEmpty)
        #expect(DesktopHider.isHidden(URL(fileURLWithPath: other)))
    }

    @Test("大小写不同的两个路径指向同一个文件：规范化后是同一条")
    func caseInsensitivePathsCanonicalize() throws {
        let desk = try makeDesktop()
        let real = try touch("Report.txt", in: desk)
        let lower = desk.appendingPathComponent("report.txt")
        #expect(DesktopHider.canonicalItemPath(lower) == DesktopHider.canonicalItemPath(URL(fileURLWithPath: real)))
        #expect(DesktopHider.canonicalItemPath(lower).hasSuffix("/Report.txt"))
    }

    @Test("看门狗恢复显示后重新启动：仍在分区里的项目会被重新隐藏")
    func rehideAfterWatchdogRestore() throws {
        let desk = try makeDesktop()
        let a = try touch("a.txt", in: desk)
        let hider = DesktopHider(desktop: desk)
        let tracked = hider.reconcile(wanted: [a], tracked: [])
        DesktopHider.setHidden(false, at: URL(fileURLWithPath: a)) // 模拟看门狗已恢复显示
        let again = hider.reconcile(wanted: [a], tracked: tracked)
        #expect(again == [a])
        #expect(DesktopHider.isHidden(URL(fileURLWithPath: a)))
    }
}
