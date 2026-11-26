import Darwin
import Foundation

/// 「下载」相关的判断（纯逻辑，便于测试）：哪些是浏览器还没下完的临时文件、
/// 一个文件是不是刚从网上下载的、桌面上哪些新文件已经下完可以收进分区。
public enum DownloadFiles {
    /// 各浏览器 / 下载工具下载途中用的临时扩展名（下完会改成正式名字，那时才算一个新文件）。
    /// Chrome / Edge / Brave `.crdownload`，Safari `.download`（是个文件夹包），Firefox `.part`，
    /// Opera `.opdownload`，其它常见 `.partial` `.!ut`（µTorrent）`.td`（迅雷）`.adadownload`。
    static let temporaryExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "!ut", "td", "adadownload", "aria2"]

    /// 不该出现在分区里 / 不该被收的名字：隐藏文件（含 .DS_Store、Tuck 自己的临时副本）、下载中的临时文件、
    /// Office 打开文档时放的 ~$ 锁文件、Icon\r。
    public static func isIgnorable(name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") || name == "Icon\r" { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return temporaryExtensions.contains(ext)
    }

    /// 是不是系统截图：截图工具会写 kMDItemIsScreenCapture 标记；没有标记时按默认名字认（截屏 / Screenshot / 屏幕快照）。
    public static func isScreenshot(url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0 { return true }
        let name = url.lastPathComponent
        return ["截屏", "Screenshot", "屏幕快照", "Screen Shot"].contains { name.hasPrefix($0) }
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

/// 桌面 / 「下载」里「新保存好的文件」的判断：不管是浏览器下载、网页里「另存为」，还是别的软件保存，
/// 只要是 Tuck 看着之后新出现、已经写完的文件就收。原有的文件一概不碰。
///
/// 怎么算「新的、写完的」：
/// - 不是临时文件（.download / .crdownload / .part …、Office 的 ~$ 锁文件、隐藏文件），旁边也没有同名的临时文件；
/// - 文件本身是最近新建的（创建时间在 `freshness` 以内）：从别处挪过来的老文件、从分区拖回桌面的文件都不算；
/// - 没有任何程序正打开着它（调用方查好传进来），并且连续两次看到大小不变；
/// - 截图默认不收（`includeScreenshots` 打开才收）。
public struct DesktopDownloadCollector: Sendable {
    /// 一个项目的快照。
    public struct Entry: Sendable {
        public var name: String
        public var size: Int64
        /// 文件的创建时间（读不到 = nil，当作不是新文件）。
        public var createdAt: Date?
        /// 系统截图（有截图标记，或名字是「截屏 / Screenshot …」）。
        public var isScreenshot: Bool
        /// 有程序正打开着它（还在写 / 正在用）。
        public var inUse: Bool
        public init(name: String, size: Int64, createdAt: Date?, isScreenshot: Bool = false, inUse: Bool = false) {
            self.name = name
            self.size = size
            self.createdAt = createdAt
            self.isScreenshot = isScreenshot
            self.inUse = inUse
        }
    }

    /// 收到的一个文件。
    public struct Ready: Equatable, Sendable {
        public var name: String
        public var isScreenshot: Bool
    }

    /// 只收「新建」的文件：创建时间离现在不超过这么久。
    public static let freshness: TimeInterval = 10 * 60

    /// 已经看过、不用再管的名字（启动时的内容全部在这里）。
    private var known: Set<String>
    /// 新出现、还在等确认写完的：名字 → 上一次看到的大小（-1 = 正被打开着，下次再看）。
    private var pending: [String: Int64] = [:]

    public init(baseline: [String]) {
        known = Set(baseline)
    }

    /// 这个名字还没看过（调用方只给这些读大小、创建时间、截图标记、是否被打开，省得每次读整个文件夹）。
    public func needsLook(_ name: String) -> Bool { !known.contains(name) }

    /// 还有没确认写完的新文件（调用方应该稍后再看一次）。
    public var hasPending: Bool { !pending.isEmpty }

    /// 看一次，返回这次确认可以收的文件。
    public mutating func step(_ entries: [Entry], now: Date, includeScreenshots: Bool) -> [Ready] {
        let names = Set(entries.map(\.name))
        known.formIntersection(names)                       // 被删 / 被拖走的忘掉，同名再存一次还能收
        pending = pending.filter { names.contains($0.key) }
        var ready: [Ready] = []
        for entry in entries where !known.contains(entry.name) {
            // 临时文件 / 锁文件：等它改成正式名字（或者消失）
            if DownloadFiles.isIgnorable(name: entry.name) { continue }
            // 还在下载：旁边有同名的临时文件（Firefox 会先放一个正式名字的空文件，再写 名字.part）
            if entry.size <= 0 || DownloadFiles.temporaryExtensions.contains(where: { names.contains(entry.name + "." + $0) }) {
                pending[entry.name] = nil
                continue
            }
            if entry.isScreenshot && !includeScreenshots {
                forget(entry.name)
                continue
            }
            // 不是新建的（从别处挪来的老文件、从分区拖回来的）：以后也不再看它
            guard let created = entry.createdAt, now.timeIntervalSince(created) <= Self.freshness else {
                forget(entry.name)
                continue
            }
            if entry.inUse {
                pending[entry.name] = -1 // 还开着：过一会儿再看
                continue
            }
            if let last = pending[entry.name], last == entry.size {
                forget(entry.name)
                ready.append(Ready(name: entry.name, isScreenshot: entry.isScreenshot))
            } else {
                pending[entry.name] = entry.size // 第一次看到 / 还在变大：下次再看
            }
        }
        return ready.sorted { $0.name < $1.name }
    }

    /// 某个名字不要再收了（收进分区失败、已经在分区里、或者是用户自己放回来的）。
    public mutating func forget(_ name: String) {
        known.insert(name)
        pending[name] = nil
    }
}
