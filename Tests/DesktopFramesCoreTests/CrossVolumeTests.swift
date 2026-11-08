import Foundation
import Testing
@testable import DesktopFramesCore

/// 跨卷移动的真实测试：用两个临时磁盘映像当“两块盘”，搬一个 1GB 的文件夹。
/// 比较慢，默认跳过；设置环境变量 TUCK_SLOW_TESTS=1 才运行。
@Suite("跨卷移动（1GB，需 TUCK_SLOW_TESTS=1）", .enabled(if: ProcessInfo.processInfo.environment["TUCK_SLOW_TESTS"] == "1"))
struct CrossVolumeTests {
    struct Volumes {
        let root: URL, src: URL, dst: URL
    }

    private func sh(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(args.joined(separator: " "))")
    }

    private func mount() throws -> Volumes {
        let base = ProcessInfo.processInfo.environment["TUCK_SLOW_TESTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("CrossVolume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["src", "dst"] {
            try sh(["/usr/bin/hdiutil", "create", "-quiet", "-size", "1500m", "-type", "SPARSE", "-fs", "APFS",
                    "-volname", "Tuck\(name)", root.appendingPathComponent(name).path])
            let mountPoint = root.appendingPathComponent("vol-\(name)")
            try sh(["/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path,
                    root.appendingPathComponent("\(name).sparseimage").path])
        }
        return Volumes(root: root, src: root.appendingPathComponent("vol-src"), dst: root.appendingPathComponent("vol-dst"))
    }

    private func unmount(_ v: Volumes) {
        for m in [v.src, v.dst] { try? sh(["/usr/bin/hdiutil", "detach", "-quiet", "-force", m.path]) }
        // 测试自己建的磁盘映像（每次约 2GB），卸载后删掉，避免越积越多
        try? FileManager.default.removeItem(at: v.root)
    }

    /// 在源盘上造一个 1GB 的文件夹（4 × 256MB）。
    private func makeBigFolder(on volume: URL) throws -> URL {
        let folder = volume.appendingPathComponent("大文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 1...4 {
            try sh(["/usr/sbin/mkfile", "256m", folder.appendingPathComponent("part\(i).bin").path])
        }
        return folder
    }

    private func size(_ url: URL) -> Int64 { FileOperationService.totalBytes(of: url) }

    @Test("跨卷移动 1GB 文件夹：目标完整、有进度、源进废纸篓（不是直接删除）")
    func moveBigFolder() throws {
        let v = try mount()
        defer { unmount(v) }
        let folder = try makeBigFolder(on: v.src)
        let total = size(folder)
        let dstDir = v.dst.appendingPathComponent("分区文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let reports = Locked2(0)
        let progress = TransferProgress { _, _ in reports.add() }
        let result = try FileOperationService().moveDetailed(item: folder, into: dstDir, policy: .cancel, progress: progress)
        guard case .moved(let destination) = result.outcome else { Issue.record("应已移动"); return }
        #expect(size(destination) == total)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(reports.value > 10, "进度回调次数 \(reports.value)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dstDir.path)
            .filter { $0.hasPrefix(FileOperationService.partialPrefix) }
        #expect(leftovers.isEmpty)
    }

    @Test("跨卷移动中途取消：源文件夹完整，目标既没有正式文件也没有临时副本")
    func cancelMidway() throws {
        let v = try mount()
        defer { unmount(v) }
        let folder = try makeBigFolder(on: v.src)
        let total = size(folder)
        let dstDir = v.dst.appendingPathComponent("分区文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let flag = Locked2(0)
        let progress = TransferProgress { done, all in
            if Double(done) / Double(all) > 0.3 { flag.add() }
        }
        // 进度过 30% 时取消（用一个后台线程盯着计数器）
        DispatchQueue.global().async {
            while flag.value == 0 { usleep(5_000) }
            progress.cancel()
        }
        #expect(throws: FileOperationError.cancelled) {
            _ = try FileOperationService().moveDetailed(item: folder, into: dstDir, policy: .cancel, progress: progress)
        }
        #expect(size(folder) == total)
        let left = try FileManager.default.contentsOfDirectory(atPath: dstDir.path)
        #expect(left.isEmpty, "目标残留：\(left)")
    }
}

/// 测试用的计数器（进度回调来自复制线程）。
final class Locked2: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int
    init(_ n: Int) { self.n = n }
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
