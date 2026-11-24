import Darwin
import Foundation

/// 「下载」相关的判断（纯逻辑，便于测试）：哪些是浏览器还没下完的临时文件、
/// 一个文件是不是刚从网上下载的、桌面上哪些新文件已经下完可以收进分区。
public enum DownloadFiles {
    /// 各浏览器 / 下载工具下载途中用的临时扩展名（下完会改成正式名字，那时才算一个新文件）。
    /// Chrome / Edge / Brave `.crdownload`，Safari `.download`（是个文件夹包），Firefox `.part`，
    /// Opera `.opdownload`，其它常见 `.partial` `.!ut`（µTorrent）`.td`（迅雷）`.adadownload`。
    static let temporaryExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "!ut", "td", "adadownload", "aria2"]

    /// 不该出现在分区里 / 不该被收的名字：隐藏文件（含 .DS_Store、Tuck 自己的临时副本）、下载中的临时文件、Icon\r。
    public static func isIgnorable(name: String) -> Bool {
        if name.hasPrefix(".") || name == "Icon\r" { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return temporaryExtensions.contains(ext)
    }

    /// 读系统给“从网上下载的文件”打的隔离标记，返回下载时间；没有标记 = 不是下载来的（或来源不明）。
    /// 标记格式：`标志;十六进制秒数;下载它的 App;编号`，例如 `0083;6743a1b2;Safari;…`。
    public static func quarantineDate(of url: URL) -> Date? {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return parseQuarantine(String(decoding: buffer, as: UTF8.self))
    }

    static func parseQuarantine(_ value: String) -> Date? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, let seconds = UInt64(parts[1], radix: 16), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// 桌面上「新下载完成的文件」的判断：只认 Tuck 启动（或打开这个功能）之后新出现的，
/// 并且连续两次看到大小不变才算下完。原有的桌面文件一概不碰。
public struct DesktopDownloadCollector: Sendable {
    /// 桌面上一个项目的快照。
    public struct Entry: Sendable {
        public var name: String
        public var size: Int64
        /// 隔离标记里的下载时间（没有 = nil）。
        public var downloadedAt: Date?
        public init(name: String, size: Int64, downloadedAt: Date?) {
            self.name = name
            self.size = size
            self.downloadedAt = downloadedAt
        }
    }

    /// 只收“刚从网上下载”的：下载时间离现在不超过这么久（避免把很久以前下的、刚被挪到桌面的老文件也收走）。
    public static let freshness: TimeInterval = 15 * 60

    /// 已经看过、不用再管的名字（启动时的桌面全部在这里）。
    private var known: Set<String>
    /// 新出现、还在等确认下完的：名字 → 上一次看到的大小。
    private var pending: [String: Int64] = [:]

    public init(baseline: [String]) {
        known = Set(baseline)
    }

    /// 这个名字还没看过（调用方只给这些读大小和下载标记，省得每次把整个桌面都读一遍）。
    public func needsLook(_ name: String) -> Bool { !known.contains(name) }

    /// 还有没确认下完的新文件（调用方应该稍后再看一次）。
    public var hasPending: Bool { !pending.isEmpty }

    /// 看一次桌面，返回这次确认可以收进分区的名字。
    /// - webOnly: true = 只收带「从网上下载」标记且是最近下载的；false = 所有新出现的文件都收（比如截图）。
    public mutating func step(_ entries: [Entry], now: Date, webOnly: Bool) -> [String] {
        let names = Set(entries.map(\.name))
        known.formIntersection(names)                       // 被删 / 被拖走的忘掉，同名再下载一次还能收
        pending = pending.filter { names.contains($0.key) }
        var ready: [String] = []
        for entry in entries where !known.contains(entry.name) {
            if DownloadFiles.isIgnorable(name: entry.name) { continue } // 下载中的临时文件：等它改成正式名字
            // 还在下载：旁边有同名的临时文件（Firefox 会先放一个正式名字的空文件，再写 名字.part；
            // 有的工具也会这样）——等临时文件消失、正式文件有内容了再说
            if entry.size <= 0 || DownloadFiles.temporaryExtensions.contains(where: { names.contains(entry.name + "." + $0) }) {
                pending[entry.name] = nil
                continue
            }
            if webOnly {
                guard let at = entry.downloadedAt, abs(now.timeIntervalSince(at)) <= Self.freshness else {
                    known.insert(entry.name) // 不是刚下载的：以后也不再看它
                    pending[entry.name] = nil
                    continue
                }
            }
            if let last = pending[entry.name], last == entry.size {
                known.insert(entry.name)
                pending[entry.name] = nil
                ready.append(entry.name)
            } else {
                pending[entry.name] = entry.size // 第一次看到 / 还在变大：下次再看
            }
        }
        return ready.sorted()
    }

    /// 某个名字不要再收了（比如收进分区失败、或者已经在分区里）。
    public mutating func forget(_ name: String) {
        known.insert(name)
        pending[name] = nil
    }
}
