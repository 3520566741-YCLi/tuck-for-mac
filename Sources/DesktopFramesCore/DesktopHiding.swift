import Darwin
import Foundation

/// “在桌面上隐藏已收纳的原图标”：对放进普通 / 应用分区的**桌面直属**项目设置访达隐藏标记
/// （等同 `chflags hidden`），文件原地不动、不改名、不改内容；不需要时取消标记。
///
/// 安全规则：
/// - 只处理 `desktop` 目录的直接子项（不递归、不处理别处的文件）；
/// - 只取消 Tuck 自己设置的隐藏（记录在 `tracked` 里），用户本来就隐藏的文件绝不取消；
/// - 用户原本已隐藏的文件不会被记成“Tuck 隐藏的”；
/// - 记录持久化在布局里，崩溃后重启再对账，状态可恢复一致。
/// 用书签找被移走文件的结果。
public enum RelocateResult {
    /// 找到了新位置。
    case found(URL)
    /// 文件确实不在了（已删除 / 没有书签可用）。
    case gone
    /// 暂时找不到（所在的外接盘没接上等）：保留记录，下次再试。
    case unavailable
}

public struct DesktopHider {
    public let desktop: URL

    public init(desktop: URL) {
        self.desktop = desktop
    }

    /// 是否为桌面的直接子项。
    public func isOnDesktop(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return Self.canonical(url.deletingLastPathComponent()) == Self.canonical(desktop)
    }

    /// 对账：让“Tuck 隐藏的集合”等于 `wanted`（应隐藏的桌面项目路径）。
    /// - Parameters:
    ///   - wanted: 当前应该隐藏的路径（只会考虑其中的桌面直属项目）；功能关闭时传空集。
    ///   - tracked: 之前由 Tuck 隐藏的路径（来自布局）。
    /// - Returns: 新的 tracked 集合（调用方写回布局）。
    ///   - record: 每次准备隐藏某个文件**之前**先调用（写入记录），保证即使在隐藏之后、
    ///     写记录之前崩溃，也不会留下“Tuck 隐藏了却没记下”的文件。
    ///   - relocate: 被隐藏的文件在原路径找不到时（被别的程序移走 / 改名），用书签找到它的新位置，
    ///     以便把隐藏标记取消掉，免得它在新位置“消失”。
    public func reconcile(
        wanted: Set<String>,
        tracked: Set<String>,
        record: (Set<String>) -> Void = { _ in },
        relocate: (String) -> RelocateResult = { _ in .gone },
        isOriginal: (String) -> Bool = { _ in true }
    ) -> Set<String> {
        let fm = FileManager.default
        let wantedOnDesktop = Set(wanted.filter { isOnDesktop(URL(fileURLWithPath: $0)) })
        var result = tracked

        // 1) 不再需要隐藏的：只恢复我们自己隐藏的那些
        for path in tracked.subtracting(wantedOnDesktop) {
            let url = URL(fileURLWithPath: path)
            // 记录只可能是桌面直属项目；被篡改 / 来历不明的记录直接作废，不去动别处的文件
            guard isOnDesktop(url) else {
                result.remove(path)
                continue
            }
            if fm.fileExists(atPath: path) {
                if isOriginal(path) || Self.hasTuckMark(url) {
                    // 还是当初那个文件，或带着 Tuck 的标记（编辑器“安全保存”换了 inode 也会带着）
                    if Self.setHidden(false, at: url) { result.remove(path) }
                    // 失败（权限等）就留在记录里，下次再试
                } else {
                    // 原路径上已换成另一个文件（用户删了原文件又放了同名的）：不碰它；
                    // 原文件若被移到了别处，用书签找到并取消隐藏
                    if case .found(let moved) = relocate(path), Self.hasTuckMark(moved) {
                        Self.setHidden(false, at: moved)
                    }
                    result.remove(path)
                }
            } else {
                // 文件已不在原路径：用书签找新位置，仍是隐藏状态就恢复显示
                switch relocate(path) {
                case .found(let moved):
                    if !Self.isHidden(moved) || Self.setHidden(false, at: moved) {
                        result.remove(path)
                    } // 取消隐藏失败：保留记录，下次再试
                case .gone:
                    result.remove(path)
                case .unavailable:
                    break // 外接盘没接上等：保留记录
                }
            }
        }

        // 2) 新需要隐藏的：原本就隐藏的不接管。整批先记下（一次写盘），再逐个隐藏。
        var toHide: [String] = []
        for path in wantedOnDesktop.subtracting(tracked) {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path) else { continue }
            // 符号链接不处理（避免标记作用到链接指向的别处文件）
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if Self.isHidden(url) { continue } // 用户自己隐藏的，不记成我们的
            toHide.append(path)
        }
        // 记录里有、但现在其实是可见的（例如看门狗在 Tuck 崩溃后已恢复显示）：仍在分区里就重新隐藏
        for path in wantedOnDesktop.intersection(tracked) {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path), !Self.isHidden(url),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            toHide.append(path)
        }
        if !toHide.isEmpty {
            result.formUnion(toHide)
            record(result) // 先记下，再隐藏
            for path in toHide where !Self.setHidden(true, at: URL(fileURLWithPath: path)) {
                result.remove(path)
            }
        }
        record(result)
        return result
    }

    /// 全部恢复（退出 / 关闭功能时用）。返回仍未恢复成功的路径。
    public func restoreAll(
        tracked: Set<String>,
        record: (Set<String>) -> Void = { _ in },
        relocate: (String) -> RelocateResult = { _ in .gone },
        isOriginal: (String) -> Bool = { _ in true }
    ) -> Set<String> {
        reconcile(wanted: [], tracked: tracked, record: record, relocate: relocate, isOriginal: isOriginal)
    }

    // MARK: - 底层

    public static func isHidden(_ url: URL) -> Bool {
        // 不能用 resourceValues 缓存：每次新建 URL 读取当前值
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false
    }

    /// Tuck 自己的扩展属性标记：隐藏时打上、取消隐藏时去掉。
    /// 编辑器“安全保存”（换 inode）时扩展属性会被一起复制，借此认出“这是 Tuck 隐藏的那个文件”。
    static let markName = "io.github.tuckformac.tuck.hidden"

    public static func hasTuckMark(_ url: URL) -> Bool {
        getxattr(url.path, markName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func setTuckMark(_ on: Bool, at url: URL) {
        if on {
            var one: UInt8 = 1
            _ = setxattr(url.path, markName, &one, 1, 0, XATTR_NOFOLLOW)
        } else {
            _ = removexattr(url.path, markName, XATTR_NOFOLLOW)
        }
    }

    /// 设置 / 取消访达隐藏标记（UF_HIDDEN），不跟随符号链接到别处；同时维护 Tuck 标记。
    @discardableResult
    public static func setHidden(_ hidden: Bool, at url: URL) -> Bool {
        var target = URL(fileURLWithPath: url.path)
        var values = URLResourceValues()
        values.isHidden = hidden
        do {
            try target.setResourceValues(values)
            guard isHidden(target) == hidden else { return false }
            setTuckMark(hidden, at: target)
            return true
        } catch {
            return false
        }
    }

    /// 文件的“真实路径”：按文件身份取回系统记录的大小写（APFS 默认不区分大小写，
    /// `~/Desktop/Foo` 和 `~/Desktop/foo` 是同一个文件）。文件不存在时原样返回。
    /// 只修正最后一级名字的大小写，父目录保持原样（不解析其中的符号链接，入口仍是用户看到的路径）。
    public static func canonicalItemPath(_ url: URL) -> String {
        let standard = url.standardizedFileURL
        guard let ref = (standard as NSURL).fileReferenceURL(),
              let real = (ref as NSURL).filePathURL,
              real.lastPathComponent.caseInsensitiveCompare(standard.lastPathComponent) == .orderedSame
        else { return standard.path }
        return standard.deletingLastPathComponent().appendingPathComponent(real.lastPathComponent).path
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Tuck 隐藏过哪些桌面文件的记录：单独存一个小文件（不放进布局，
/// 这样“恢复备份”替换布局时也不会丢失记录），原子写入。
/// 每条记录除了路径还存一份文件书签，文件被别处移走后仍能找到它、取消隐藏。
/// 兼容旧格式（只有路径的字符串数组）。
public final class HiddenRegistry {
    public let file: URL
    public private(set) var paths: Set<String>
    private var bookmarks: [String: Data] = [:]
    /// 隐藏时的文件编号（inode），用于确认原路径上还是同一个文件。
    private var fileNumbers: [String: UInt64] = [:]

    private struct Entry: Codable {
        var path: String
        var bookmark: Data?
        var fileNumber: UInt64?
    }

    /// 看门狗读取的清单文件（与 file 同目录）。
    public var listFile: URL { file.deletingPathExtension().appendingPathExtension("list") }

    public init(file: URL) {
        self.file = file
        paths = []
        guard let data = try? Data(contentsOf: file) else { return }
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            for e in entries where e.path.hasPrefix("/") {
                paths.insert(e.path)
                if let b = e.bookmark { bookmarks[e.path] = b }
                if let n = e.fileNumber { fileNumbers[e.path] = n }
            }
        } else if let list = try? JSONDecoder().decode([String].self, from: data) {
            paths = Set(list.filter { $0.hasPrefix("/") }) // 旧格式：只有路径
        }
    }

    /// 给看门狗用的极简清单：NUL 分隔的路径（看门狗不加载 Foundation，读不了 JSON）。
    public func writeList() throws {
        var list = Data()
        for p in paths.sorted() { list.append(contentsOf: Array(p.utf8)); list.append(0) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try list.write(to: listFile, options: .atomic)
    }

    /// 用书签找回文件的当前位置（原路径找不到时调用）。
    public func locate(_ path: String) -> RelocateResult {
        guard let data = bookmarks[path] else { return .gone }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return .gone }
            return .found(url)
        } catch {
            // 卷不可用（外接盘没接）时保留记录；其它解析失败视为文件已不在
            let code = (error as NSError).code
            return (code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError) ? .gone : .unavailable
        }
    }

    /// 原路径上是否仍是当初隐藏的那个文件（没有记录编号的旧记录视为是）。
    public func isOriginal(_ path: String) -> Bool {
        guard let expected = fileNumbers[path] else { return true }
        return Self.fileNumber(path) == expected
    }

    static func fileNumber(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    public func update(_ newPaths: Set<String>) {
        // 给缺书签 / 缺编号的记录补建（含旧格式升级上来的记录）
        var backfilled = false
        for path in newPaths where FileManager.default.fileExists(atPath: path) {
            if bookmarks[path] == nil,
               let b = try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[path] = b; backfilled = true
            }
            if fileNumbers[path] == nil, let n = Self.fileNumber(path) {
                fileNumbers[path] = n; backfilled = true
            }
        }
        guard newPaths != paths || backfilled else { return }
        for removed in paths.subtracting(newPaths) {
            bookmarks.removeValue(forKey: removed)
            fileNumbers.removeValue(forKey: removed)
        }
        paths = newPaths
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entries = paths.sorted().map { Entry(path: $0, bookmark: bookmarks[$0], fileNumber: fileNumbers[$0]) }
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            try writeList()
        } catch {
            // 尽力而为：写不进去时内存里的记录仍有效，下次对账再写
        }
    }
}
