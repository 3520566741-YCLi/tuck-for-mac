import Darwin
import Foundation

/// 「Tuck 分区」入口文件夹：在个人文件夹里按分区列出指向原文件的快捷方式（符号链接）。
///
/// 为什么要有它：Tuck 把收进分区的桌面原文件打上系统“隐藏”标记，桌面才干净；但这个标记对所有软件
/// 都生效，别的软件的“打开 / 上传”窗口里也就看不到这些文件了。系统没有“只在桌面上隐藏”的接口，
/// 所以另给一个入口：每个分区一个子文件夹，里面是指向原文件的符号链接（链接本身不隐藏），
/// 任何软件的打开窗口点进去都能选到原文件。文件分区直接链接到它的关联文件夹。
///
/// 安全底线：
/// - 原文件一律不动（只读它们的路径）；
/// - 只增删 Tuck 自己建的东西：子文件夹和链接都带 Tuck 标记，只删带标记、已不需要的链接（删链接不会删到原文件）；
///   用户自己做的链接没有标记，绝不碰；同名的现成文件夹如果不是 Tuck 建的、里面又有东西，整个不动；
/// - 用户自己放进来的真文件 / 文件夹绝不碰；空了的 Tuck 子文件夹才用 rmdir 拿掉（不是空的就留着）。
public struct ZoneMirror: Sendable {
    public let root: URL
    static let markName = "io.github.tuckformac.tuck.mirror"

    public init(root: URL) {
        self.root = root
    }

    /// 一个分区要在入口文件夹里呈现的内容。
    public enum Entry: Equatable, Sendable {
        /// 子文件夹，里面是这些文件的链接。
        case folder(name: String, targets: [URL])
        /// 直接链接到一个文件夹（文件分区的关联文件夹）。
        case link(name: String, target: URL)

        var name: String {
            switch self {
            case .folder(let name, _), .link(let name, _): return name
            }
        }
    }

    /// 由分区列表算出入口文件夹应有的样子（纯计算，便于测试）。同名分区自动编号。
    public static func plan(for zones: [Zone], root: URL? = nil) -> [Entry] {
        var used = Set<String>()
        // 下载分区的真实文件夹本来就在入口文件夹里：不再给它建链接，名字也让出来
        let rootPath = root.map { $0.standardizedFileURL.path }
        func isInRoot(_ zone: Zone) -> Bool {
            zone.liveFolder && rootPath != nil
                && zone.backingFolderURL?.deletingLastPathComponent().standardizedFileURL.path == rootPath
        }
        for zone in zones where isInRoot(zone) {
            if let name = zone.backingFolderURL?.lastPathComponent { used.insert(name.lowercased()) }
        }
        var result: [Entry] = []
        for zone in zones where !isInRoot(zone) {
            let name = uniqueName(sanitize(zone.name), used: &used)
            if zone.kind == .folder {
                guard let folder = zone.backingFolderURL else { continue }
                result.append(.link(name: name, target: folder))
            } else {
                result.append(.folder(name: name, targets: zone.items.map(\.url)))
            }
        }
        return result
    }

    /// 文件名里不能有的字符换掉；以“.”开头会变成隐藏文件，去掉开头的点；空名字给个默认名。
    static func sanitize(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = L("分区", "Zone") }
        return String(name.prefix(120))
    }

    static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var n = 2
        while used.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }

    /// 准备好入口文件夹本身：不存在就建、空的就打上 Tuck 标记。
    /// 返回 false = 不能用（被换成了文件 / 链接，或是用户自己的、里面有东西的同名文件夹）。
    @discardableResult
    public func prepareRoot() -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) && !Self.isSymlink(root.path) {
            guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return false }
        }
        guard Self.isRealDirectory(root.path) else { return false } // 被换成了文件 / 链接：不碰
        if !Self.hasMark(root.path) {
            // 已经有个同名文件夹、不是 Tuck 建的：空的才接管，里面有东西就整个不动
            guard ((try? fm.contentsOfDirectory(atPath: root.path)) ?? ["?"]).isEmpty else { return false }
            Self.setMark(root)
        }
        return true
    }

    /// 在入口文件夹里建「下载分区」用的真实文件夹（不打 Tuck 标记：它装的是用户的文件，Tuck 永远不删它）。
    /// 同名的已经有了：是普通文件夹就直接用；被占用（是文件 / 链接）就换个编号。返回建好的位置。
    public func makeDownloadFolder(named raw: String) -> URL? {
        guard prepareRoot() else { return nil }
        let base = Self.sanitize(raw)
        var name = base
        var n = 2
        while true {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let path = url.path
            if Self.isRealDirectory(path) && !Self.hasMark(path) { return url } // 用户已有的同名文件夹：直接用
            // Tuck 给同名普通分区建的入口子文件夹：里面只有 Tuck 的链接（或空的）就接过来用——
            // 删掉这些链接（删链接不会动原文件）、去掉 Tuck 标记，从此它是装用户文件的普通文件夹
            if Self.isRealDirectory(path) && Self.hasMark(path) {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? ["?"]
                let onlyTuckLinks = contents.allSatisfy { name in
                    let p = (path as NSString).appendingPathComponent(name)
                    return Self.isSymlink(p) && Self.hasMark(p)
                }
                if onlyTuckLinks {
                    Self.removeLinks(in: path, keeping: [:])
                    removexattr(path, Self.markName, XATTR_NOFOLLOW)
                    return url
                }
            }
            if !Self.isSymlink(path) && !FileManager.default.fileExists(atPath: path) {
                return mkdir(path, 0o755) == 0 ? url : nil
            }
            name = "\(base) \(n)"
            n += 1
            if n > 99 { return nil }
        }
    }

    /// 让磁盘上的入口文件夹和 plan 一致。出错的单项跳过（下次再来），不抛错、不弹框。
    public func sync(_ plan: [Entry]) {
        let fm = FileManager.default
        guard prepareRoot() else { return }

        let wanted = Dictionary(plan.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // 1) 清掉不再需要的顶层项（只动 Tuck 的东西）
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let path = root.appendingPathComponent(name).path
            let entry = wanted[name.lowercased()]
            if Self.isSymlink(path) {
                guard Self.hasMark(path) else { continue } // 用户自己的链接：不碰
                if case .link(_, let target)? = entry, Self.linkTarget(path) == target.path { continue }
                unlink(path)
            } else if Self.isRealDirectory(path), Self.hasMark(path) {
                if case .folder? = entry { continue }
                Self.removeLinks(in: path, keeping: [:])
                rmdir(path) // 只有空了才会成功
            }
        }
        // 2) 建立 / 更新需要的项
        for entry in plan {
            let path = root.appendingPathComponent(entry.name).path
            switch entry {
            case .link(_, let target):
                if !fm.fileExists(atPath: path) && !Self.isSymlink(path) {
                    Self.makeLink(to: target.path, at: path)
                }
            case .folder(_, let targets):
                if !Self.isSymlink(path), !fm.fileExists(atPath: path) {
                    guard mkdir(path, 0o755) == 0 else { continue }
                    Self.setMark(URL(fileURLWithPath: path))
                }
                guard Self.isRealDirectory(path), Self.hasMark(path) else { continue } // 同名的是用户自己的东西：不动
                syncLinks(in: path, targets: targets)
            }
        }
    }

    /// 子文件夹里：每个目标一个同名链接（重名加编号），多余的链接删掉。
    private func syncLinks(in folder: String, targets: [URL]) {
        let fm = FileManager.default
        var used = Set<String>()
        var desired: [String: String] = [:] // 链接名 → 目标路径
        for target in targets where fm.fileExists(atPath: target.path) {
            let base = target.lastPathComponent
            let ext = (base as NSString).pathExtension
            let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                n += 1
            }
            used.insert(name.lowercased())
            desired[name] = target.path
        }
        Self.removeLinks(in: folder, keeping: desired)
        for (name, target) in desired {
            let path = (folder as NSString).appendingPathComponent(name)
            if Self.isSymlink(path) || fm.fileExists(atPath: path) { continue } // 已有（或用户自己的真文件 / 链接）
            Self.makeLink(to: target, at: path)
        }
    }

    /// 删掉文件夹里 Tuck 建的、不在 keeping 里（或目标变了）的符号链接；真文件和用户自己的链接一概不碰。
    private static func removeLinks(in folder: String, keeping: [String: String]) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            let path = (folder as NSString).appendingPathComponent(name)
            guard isSymlink(path), hasMark(path) else { continue }
            if let target = keeping[name], linkTarget(path) == target { continue }
            unlink(path)
        }
    }

    // MARK: - 底层（不跟随符号链接）

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    static func hasMark(_ path: String) -> Bool {
        getxattr(path, markName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// 建链接并给链接本身打上 Tuck 标记（不跟随到原文件，原文件不会被写任何东西）。
    static func makeLink(to target: String, at path: String) {
        guard symlink(target, path) == 0 else { return }
        setMark(URL(fileURLWithPath: path))
    }

    static func setMark(_ url: URL) {
        var one: UInt8 = 1
        _ = setxattr(url.path, markName, &one, 1, 0, XATTR_NOFOLLOW)
    }
}
