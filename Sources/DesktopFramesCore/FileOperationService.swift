import Darwin
import Foundation

/// 目标已存在同名项时的冲突处理策略。
public enum ConflictPolicy: Sendable, Equatable {
    /// 取消该项目的移动（源文件保持原位）。这是设计文档规定的默认行为。
    case cancel
    /// 保留两者：为移入项生成不冲突的新名字（如 “报告 2.pdf”）。
    case keepBoth
    /// 替换：覆盖目标位置同名项。
    case replace
}

/// 一次移动的最终结果。
public enum MoveOutcome: Sendable, Equatable {
    /// 已移动，返回最终位置（keepBoth 时会不同于原名）。
    case moved(destination: URL)
    /// 用户选择取消，未做任何改动。
    case cancelled
}

public enum FileOperationError: Error, LocalizedError, Sendable, Equatable {
    /// 待移动的源项目不存在。
    case sourceMissing
    /// 目标文件夹不存在或不可用。
    case folderMissing
    /// 撤销时发现目标项目已不在预期位置。
    case itemGone(URL)
    /// 撤销时原位置已被占用（避免覆盖，未执行）。
    case occupied(URL)
    /// 用户取消了（跨卷复制中途），源文件完好。
    case cancelled
    /// 其它底层文件系统错误。
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "要移动的项目已不存在。"
        case .folderMissing:
            return "分区关联的文件夹不存在，请重新创建分区或选择文件夹。"
        case .itemGone(let url):
            return "“\(url.lastPathComponent)”已不在目标位置（可能被移动或删除），无法撤销。"
        case .occupied(let url):
            return "原位置已有同名项目“\(url.lastPathComponent)”，为避免覆盖，未执行撤销。"
        case .cancelled:
            return "已取消，原文件保持不变。"
        case .underlying(let message):
            return message
        }
    }
}

/// 文件种类判定：用于拖放入口时区分文件 / 文件夹 / 应用。
public enum FileTypeInspector {
    public static func kind(of url: URL) -> ZoneItemKind {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".app") { return .application }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? .folder : .file
    }
}

/// 文件操作服务：真实文件移动（带冲突处理与跨卷回退）与一次撤销。
///
/// - 冲突默认取消，绝不自动覆盖（见设计文档第 5 节）。
/// - 跨卷移动（源与目标不在同一卷）自动退化为“复制 + 删除源”，成功后同样可撤销。
/// - 本身无状态：撤销记录由调用方持久化到布局文档。
public struct FileOperationService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - 移动

    /// 把 item 移入 folder。目标已存在同名项时按 policy 处理。
    public func move(item: URL, into folder: URL, policy: ConflictPolicy) throws -> MoveOutcome {
        try moveDetailed(item: item, into: folder, policy: policy).outcome
    }

    /// 同 move，另外返回“替换”时被移到废纸篓的旧文件位置（供撤销时放回）。
    ///
    /// 安全规则：
    /// - 源文件已经在目标文件夹里（同一个文件）时直接返回 .cancelled，绝不“替换自己”；
    /// - “替换”不永久删除旧文件，而是移到废纸篓；
    public func moveDetailed(
        item: URL, into folder: URL, policy: ConflictPolicy, progress: TransferProgress? = nil
    ) throws -> (outcome: MoveOutcome, replacedTrashURL: URL?) {
        guard fileManager.fileExists(atPath: item.path) else {
            throw FileOperationError.sourceMissing
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileOperationError.folderMissing
        }

        // 源已在目标文件夹中：什么都不做（拖回同一分区 / 两个分区共用同一文件夹）。
        if Self.canonical(item.deletingLastPathComponent()) == Self.canonical(folder) {
            return (.cancelled, nil)
        }

        let target = folder.appendingPathComponent(item.lastPathComponent)
        var destination = target

        if fileManager.fileExists(atPath: target.path) {
            // 目标与源是同一个文件（硬链接 / 符号链接指向同处）：不动。
            if isSameFile(item, target) { return (.cancelled, nil) }
            switch policy {
            case .cancel:
                return (.cancelled, nil)
            case .keepBoth:
                destination = uniqueDestination(for: item, in: folder)
            case .replace:
                break // 下方把旧目标移到废纸篓
            }
        }

        var trashed: URL?
        if fileManager.fileExists(atPath: destination.path) {
            // replace：用户已明确选择替换。旧文件移到废纸篓（可找回），不永久删除。
            do {
                var resulting: NSURL?
                try fileManager.trashItem(at: destination, resultingItemURL: &resulting)
                trashed = resulting as URL?
            } catch {
                throw FileOperationError.underlying("无法替换“\(destination.lastPathComponent)”：\(error.localizedDescription)")
            }
        }

        do {
            try performMove(from: item, to: destination, progress: progress)
        } catch {
            // 移入失败：把刚移到废纸篓的旧文件放回原处，保持现状。
            if let trashed, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: trashed, to: destination)
            }
            throw error
        }
        return (.moved(destination: destination), trashed)
    }

    // MARK: - 复制（按住 ⌥ 拖放，和访达一样）

    /// 把 item 复制到 folder，源文件不动。
    ///
    /// - 复制到源所在的同一个文件夹：和访达一样自动另起名字（`名字 2.ext`），不弹冲突；
    /// - 其它冲突按 policy：取消 / 保留两者 / 替换（旧文件移到废纸篓）；
    /// - 先复制到目标文件夹里的隐藏临时名，完成后原子改名，中途失败 / 取消只删临时副本；
    /// - 不允许把文件夹复制进它自己里面。
    public func copyDetailed(
        item: URL, into folder: URL, policy: ConflictPolicy, progress: TransferProgress? = nil
    ) throws -> (outcome: MoveOutcome, replacedTrashURL: URL?) {
        guard fileManager.fileExists(atPath: item.path) else {
            throw FileOperationError.sourceMissing
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileOperationError.folderMissing
        }
        let source = Self.canonical(item), target = Self.canonical(folder)
        if target == source || target.hasPrefix(source + "/") {
            throw FileOperationError.underlying("不能把“\(item.lastPathComponent)”复制到它自己里面。")
        }

        var destination = folder.appendingPathComponent(item.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            if Self.canonical(item.deletingLastPathComponent()) == target {
                destination = uniqueDestination(for: item, in: folder)
            } else {
                switch policy {
                case .cancel: return (.cancelled, nil)
                case .keepBoth: destination = uniqueDestination(for: item, in: folder)
                case .replace: break
                }
            }
        }

        let temp = folder.appendingPathComponent("\(Self.partialPrefix)\(UUID().uuidString)")
        PartialJournal.add(temp)
        defer { PartialJournal.remove(temp) }
        do {
            try copyWithProgress(from: item, to: temp, progress: progress)
        } catch {
            Self.removePartial(temp)
            throw error
        }
        if progress?.isCancelled == true {
            Self.removePartial(temp)
            throw FileOperationError.cancelled
        }

        var trashed: URL?
        if fileManager.fileExists(atPath: destination.path) {
            // 只有用户明确选“替换”才会走到这里：旧文件进废纸篓（可找回）
            do {
                var resulting: NSURL?
                try fileManager.trashItem(at: destination, resultingItemURL: &resulting)
                trashed = resulting as URL?
            } catch {
                Self.removePartial(temp)
                throw FileOperationError.underlying("无法替换“\(destination.lastPathComponent)”：\(error.localizedDescription)")
            }
        }
        if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
            let reason = String(cString: strerror(errno))
            Self.removePartial(temp)
            if let trashed, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: trashed, to: destination)
            }
            throw FileOperationError.underlying("复制失败：\(reason)")
        }
        Self.applyMetadata(from: item.path, to: destination.path)
        return (.moved(destination: destination), trashed)
    }

    /// 规范化路径（解析符号链接、去掉 ./..），用于“是否同一位置”的比较。
    public static func canonicalPath(_ url: URL) -> String { canonical(url) }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 两个路径是否指向同一个文件（按文件系统身份比较）。
    private func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let ia = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
              let ib = try? b.resourceValues(forKeys: keys).fileResourceIdentifier else { return false }
        return ia.isEqual(ib)
    }

    /// 撤销一次（或一批中某条）移动：把项目放回原位置。
    /// 前置条件：destination 存在且 source 未被占用，否则抛错（绝不覆盖）。
    public func undo(_ record: MoveUndoRecord, progress: TransferProgress? = nil) throws {
        guard fileManager.fileExists(atPath: record.destination.path) else {
            throw FileOperationError.itemGone(record.destination)
        }
        if fileManager.fileExists(atPath: record.source.path) {
            throw FileOperationError.occupied(record.source)
        }
        try performMove(from: record.destination, to: record.source, progress: progress)
        // “替换”时被移到废纸篓的旧文件：放回原位（尽力而为，位置已被占用就留在废纸篓）。
        if let trashed = record.replacedTrashURL,
           fileManager.fileExists(atPath: trashed.path),
           !fileManager.fileExists(atPath: record.destination.path) {
            try? fileManager.moveItem(at: trashed, to: record.destination)
        }
    }

    /// 把 item 精确移回原位置 original（“放回桌面原位置”用）。
    /// - 目标（original）已存在时不覆盖，返回 .cancelled；
    /// - original 所在目录不存在时抛 .folderMissing（调用方可回退到桌面根目录）。
    public func moveBack(item: URL, toOriginal original: URL) throws -> MoveOutcome {
        guard fileManager.fileExists(atPath: item.path) else {
            throw FileOperationError.sourceMissing
        }
        let parent = original.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileOperationError.folderMissing
        }
        if fileManager.fileExists(atPath: original.path) {
            return .cancelled // 原位置已有同名项目，绝不覆盖
        }
        try performMove(from: item, to: original)
        return .moved(destination: original)
    }

    /// 为“保留两者”生成不冲突的名字：`名字 2.扩展名`、`名字 3.扩展名` …（扩展名可无）。
    public func uniqueDestination(for item: URL, in folder: URL) -> URL {
        let base = item.deletingPathExtension().lastPathComponent
        let ext = item.pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    // MARK: - 内部

    /// 跨卷临时文件的名字前缀（复制完成并校验前都用这个隐藏名字，不会被当成正式文件）。
    public static let partialPrefix = ".tuck-partial-"

    private func performMove(from: URL, to: URL, progress: TransferProgress? = nil) throws {
        // 先判断是否跨卷：FileManager.moveItem 遇到跨卷会自己“复制 + 永久删除源”，
        // 没有进度、不能取消、源也不进废纸篓，所以跨卷一律走我们自己的安全流程。
        if !Self.sameVolume(from, to.deletingLastPathComponent()) {
            try crossVolumeMove(from: from, to: to, progress: progress)
            return
        }
        do {
            try fileManager.moveItem(at: from, to: to) // 同卷：原子改名，瞬间完成
        } catch {
            guard Self.isCrossDevice(error) else {
                throw FileOperationError.underlying("移动“\(from.lastPathComponent)”失败：\(error.localizedDescription)")
            }
            try crossVolumeMove(from: from, to: to, progress: progress)
        }
    }

    /// 跨卷移动，任何时刻至少有一份完整的文件：
    /// 1. 复制到目标文件夹里的隐藏临时名（可报进度、可取消；失败 / 取消只删这个临时副本）；
    /// 2. 复制完成后在目标卷内原子改名为正式名字；
    /// 3. 最后才把源文件移到废纸篓（失败就两份都保留并报错）。
    private func crossVolumeMove(from: URL, to: URL, progress: TransferProgress?) throws {
        if fileManager.fileExists(atPath: to.path) {
            throw FileOperationError.underlying("目标位置已有“\(to.lastPathComponent)”，未执行跨卷移动。")
        }
        // 源所在的盘没有废纸篓（网络盘、部分 U 盘）：移完没法把原文件放进废纸篓，干脆不做，提前说明
        if (try? fileManager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: from, create: true)) == nil {
            throw FileOperationError.underlying(
                "“\(from.lastPathComponent)”所在的盘不支持废纸篓。为避免永久删除原文件，Tuck 不跨盘移动它，请在访达里复制。"
            )
        }
        // 临时名只用前缀 + UUID（不带原名，避免长文件名超出系统上限）；先登记，崩溃后下次启动也能清掉
        let temp = to.deletingLastPathComponent().appendingPathComponent("\(Self.partialPrefix)\(UUID().uuidString)")
        PartialJournal.add(temp)
        defer { PartialJournal.remove(temp) }
        do {
            try copyWithProgress(from: from, to: temp, progress: progress)
        } catch {
            Self.removePartial(temp) // 只删 Tuck 自己的未完成临时副本，源文件完好
            throw error
        }
        if progress?.isCancelled == true {
            Self.removePartial(temp)
            throw FileOperationError.cancelled
        }
        // 原子改名，且目标已存在时绝不覆盖（RENAME_EXCL）
        if renamex_np(temp.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            let reason = String(cString: strerror(errno))
            Self.removePartial(temp)
            throw FileOperationError.underlying("跨卷移动失败：\(reason)")
        }
        // 权限 / 锁定标记等最后再补（复制过程中保持可写，取消时才删得掉临时副本）
        Self.applyMetadata(from: from.path, to: to.path)
        do {
            try fileManager.trashItem(at: from, resultingItemURL: nil)
        } catch {
            throw FileOperationError.underlying(
                "已复制到“\(to.path)”，但原文件未能移到废纸篓（两份都保留）：\(error.localizedDescription)"
            )
        }
    }

    /// 递归复制，边复制边报告字节进度；取消时在当前 8MB 块之后立即停止。
    /// 普通文件按块自己复制（可中途取消），复制完再用系统 copyfile 补上权限、扩展属性等元数据；
    /// 文件夹逐层建立；符号链接按链接本身复制（不跟随）。
    private func copyWithProgress(from: URL, to: URL, progress: TransferProgress?) throws {
        let counter = CopyCounter(progress: progress, total: Self.totalBytes(of: from))
        try copyNode(from: from.path, to: to.path, counter: counter)
        progress?.report(counter.total, counter.total)
    }

    private func copyNode(from: String, to: String, counter: CopyCounter) throws {
        if counter.progress?.isCancelled == true { throw FileOperationError.cancelled }
        var st = stat()
        guard lstat(from, &st) == 0 else { throw posixError("读取") }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            guard mkdir(to, 0o700) == 0 else { throw posixError("创建文件夹") }
            let entries = try fileManager.contentsOfDirectory(atPath: from)
            for name in entries {
                try copyNode(from: from + "/" + name, to: to + "/" + name, counter: counter)
            }
            _ = copyfile(from, to, nil, copyfile_flags_t(COPYFILE_XATTR)) // 扩展属性先复制；权限等改名后再补
        case S_IFREG:
            try copyFileData(from: from, to: to, counter: counter)
            guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else { throw posixError("复制属性") }
        default:
            // 符号链接等特殊项：交给系统按原样复制（不跟随链接）
            guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) == 0 else { throw posixError("复制") }
        }
    }

    private func copyFileData(from: String, to: String, counter: CopyCounter) throws {
        let input = open(from, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw posixError("打开") }
        defer { close(input) }
        let output = open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw posixError("创建") }
        defer { close(output) }
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            if counter.progress?.isCancelled == true { throw FileOperationError.cancelled }
            let n = read(input, buffer, chunk)
            if n < 0 { throw posixError("读取") }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = write(output, buffer + written, n - written)
                if w < 0 { throw posixError("写入") }
                written += w
            }
            counter.add(Int64(n))
        }
        guard fsync(output) == 0 else { throw posixError("写盘") } // 确认真的写到了目标盘上
    }

    private func posixError(_ action: String) -> FileOperationError {
        .underlying("跨卷复制失败（\(action)）：\(String(cString: strerror(errno)))")
    }

    private final class CopyCounter {
        let progress: TransferProgress?
        let total: Int64
        private(set) var done: Int64 = 0
        init(progress: TransferProgress?, total: Int64) {
            self.progress = progress
            self.total = max(total, 1)
        }
        func add(_ n: Int64) {
            done += n
            progress?.report(done, total)
        }
    }

    /// 改名成功后，由内到外把权限、所有者、锁定标记、ACL、时间补到新副本上（尽力而为，失败不影响数据）。
    static func applyMetadata(from: String, to: String) {
        var st = stat()
        guard lstat(from, &st) == 0 else { return }
        if st.st_mode & S_IFMT == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: from) {
            for name in names { applyMetadata(from: from + "/" + name, to: to + "/" + name) }
        }
        if st.st_mode & S_IFMT != S_IFLNK {
            _ = copyfile(from, to, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_STAT))
        }
    }

    /// 删除 Tuck 自己的未完成临时副本：先解除里面可能存在的只读 / 锁定，再删。
    /// 只接受名字以固定前缀开头的路径，绝不会删别的东西。
    public static func removePartial(_ url: URL) {
        guard url.lastPathComponent.hasPrefix(partialPrefix) else { return }
        func unlock(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            if st.st_mode & S_IFMT == S_IFLNK { return }
            _ = lchflags(path, 0)
            _ = chmod(path, (st.st_mode & 0o7777) | 0o700)
            if st.st_mode & S_IFMT == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                for name in names { unlock(path + "/" + name) }
            }
        }
        unlock(url.path)
        try? FileManager.default.removeItem(at: url)
    }

    /// 两个位置是否在同一个卷上（拿不到卷信息时按“不同卷”处理，走更安全的流程）。
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: key).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: key).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    /// 要复制的总字节数（文件夹则累加其中所有文件）。
    static func totalBytes(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        if let size = try? url.resourceValues(forKeys: keys).fileSize, (try? url.resourceValues(forKeys: keys).isRegularFile) == true {
            return Int64(size)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        while let f = e?.nextObject() as? URL {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    /// 判断是否为跨卷错误（EXDEV，POSIX 错误码 18）。
    /// 任何 Error 都可无条件桥接为 NSError，无需条件转换。
    private static func isCrossDevice(_ error: Error) -> Bool {
        func isExDev(_ anyError: Error) -> Bool {
            let nsError = anyError as NSError
            return nsError.domain == NSPOSIXErrorDomain && nsError.code == 18
        }
        if isExDev(error) { return true }
        let nsError = error as NSError
        return nsError.underlyingErrors.contains { isExDev($0) }
    }
}

/// 一次文件移动的进度与取消开关（可跨线程使用）。
public final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let onReport: @Sendable (Int64, Int64) -> Void

    public init(report: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
        onReport = report
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
    func report(_ done: Int64, _ total: Int64) { onReport(done, total) }
}

/// 未完成临时副本的登记簿：跨卷复制开始前登记、结束后注销；
/// 万一中途崩溃，下次启动按登记清理（覆盖任意目标文件夹，不只是分区文件夹）。
public enum PartialJournal {
    private static let lock = NSLock()
    /// 由 App 在启动时设置（Application Support 下的文件）。
    nonisolated(unsafe) public static var file: URL?

    static func add(_ url: URL) { mutate { $0.insert(url.path) } }
    static func remove(_ url: URL) { mutate { $0.remove(url.path) } }

    /// 启动时调用：清掉登记里仍然存在的临时副本，然后清空登记。
    public static func cleanUp() {
        for path in load() { FileOperationService.removePartial(URL(fileURLWithPath: path)) }
        mutate { $0.removeAll() }
    }

    private static func load() -> Set<String> {
        guard let file, let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private static func mutate(_ change: (inout Set<String>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        var set = load()
        change(&set)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(set.sorted()).write(to: file, options: .atomic)
    }
}
