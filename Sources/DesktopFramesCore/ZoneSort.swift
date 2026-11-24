import Foundation

/// 分区里的项目怎么排（只影响显示顺序，绝不改名、不移动任何文件）。
///
/// - `manual`: 手动排列（默认）：就是分区里保存的顺序，拖动可调整。
/// - 其它：自动排序。新放进来的项目会直接出现在该在的位置；分区里保存的手动顺序原样保留，
///   切回“无”就回到原来的手动排列。
public enum ZoneSortOrder: String, Codable, Sendable, CaseIterable {
    case manual
    case name
    case kind
    case dateModified
    case dateAdded
    case size

    public var displayName: String {
        switch self {
        case .manual: return L("无", "None")
        case .name: return L("名称", "Name")
        case .kind: return L("种类", "Kind")
        case .dateModified: return L("修改日期", "Date Modified")
        case .dateAdded: return L("添加日期", "Date Added")
        case .size: return L("大小", "Size")
        }
    }

    /// 这个排序默认是不是“从大到小 / 从新到旧”（和访达一样：日期新的在前、大的在前）。
    var naturallyDescending: Bool {
        switch self {
        case .dateModified, .dateAdded, .size: return true
        case .manual, .name, .kind: return false
        }
    }
}

/// 排序要用到的文件信息。拿不到（文件不在了 / 卷没挂载）时为 nil，这样的项目排在最后。
public struct ZoneSortKeys: Equatable, Sendable {
    public var kind: String?
    public var modified: Date?
    public var added: Date?
    public var size: Int64?

    public init(kind: String? = nil, modified: Date? = nil, added: Date? = nil, size: Int64? = nil) {
        self.kind = kind
        self.modified = modified
        self.added = added
        self.size = size
    }

    /// 读一个文件的排序信息（只读，不改任何东西）。文件夹 / App 包大小按 0 算（和访达默认不算文件夹大小一致）。
    public static func read(_ url: URL, for order: ZoneSortOrder) -> ZoneSortKeys {
        var keys: Set<URLResourceKey> = []
        switch order {
        case .manual, .name: return ZoneSortKeys()
        case .kind: keys = [.localizedTypeDescriptionKey]
        case .dateModified: keys = [.contentModificationDateKey]
        case .dateAdded: keys = [.addedToDirectoryDateKey, .creationDateKey]
        case .size: keys = [.fileSizeKey, .isDirectoryKey]
        }
        guard let v = try? url.resourceValues(forKeys: keys) else { return ZoneSortKeys() }
        var result = ZoneSortKeys()
        result.kind = v.localizedTypeDescription
        result.modified = v.contentModificationDate
        result.added = v.addedToDirectoryDate ?? v.creationDate
        if order == .size {
            result.size = v.isDirectory == true ? 0 : v.fileSize.map(Int64.init)
        }
        return result
    }
}

public enum ZoneSorter {
    /// 显示用的名字：和分区里显示的一致（有自定义显示名用它，否则用文件名；.app 去掉扩展名）。
    public static func sortName(_ item: ZoneItem) -> String {
        if let name = item.displayName, !name.isEmpty { return name }
        let last = item.url.lastPathComponent
        if item.kind == .application, last.lowercased().hasSuffix(".app") {
            return String(last.dropLast(4))
        }
        return last
    }

    /// 按名字比较：和访达一样（不分大小写、数字按大小 file2 在 file10 前面、按系统语言排，中文系统下汉字按拼音）。
    public static func compareNames(_ a: String, _ b: String, locale: Locale = .current) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive], range: nil, locale: locale)
    }

    /// 排好的项目。
    /// - Parameters:
    ///   - reversed: 反过来排（名称 Z→A、日期旧的在前……）。
    ///   - keys: 取某个项目的排序信息（测试里可以注入；默认读文件）。
    /// - 规则：先按选的那一项排；一样时按名字；名字也一样时保持分区里原来的顺序（稳定，不会来回跳）。
    ///   拿不到信息的项目（文件不在了）不管正序倒序都排最后。
    public static func sorted(
        _ items: [ZoneItem],
        by order: ZoneSortOrder,
        reversed: Bool = false,
        locale: Locale = .current,
        keys: ((ZoneItem) -> ZoneSortKeys)? = nil
    ) -> [ZoneItem] {
        guard order != .manual, items.count > 1 else { return items }
        struct Entry {
            let index: Int
            let item: ZoneItem
            let name: String
            let keys: ZoneSortKeys
        }
        let entries = items.enumerated().map { i, item in
            Entry(index: i, item: item, name: sortName(item), keys: order == .name ? ZoneSortKeys() : (keys?(item) ?? ZoneSortKeys.read(item.url, for: order)))
        }
        let descending = order.naturallyDescending != reversed

        /// 主排序项的比较结果；某一边拿不到信息时返回 .missing（缺的那边不管正倒序都排最后）。
        func primary(_ a: Entry, _ b: Entry) -> Primary {
            switch order {
            case .manual, .name: return .value(.orderedSame)
            case .kind: return compareOptional(a.keys.kind, b.keys.kind) { compareNames($0, $1, locale: locale) }
            case .dateModified: return compareOptional(a.keys.modified, b.keys.modified, plain)
            case .dateAdded: return compareOptional(a.keys.added, b.keys.added, plain)
            case .size: return compareOptional(a.keys.size, b.keys.size, plain)
            }
        }

        let result = entries.sorted { a, b in
            switch primary(a, b) {
            case .missing(let aIsMissing):
                return !aIsMissing
            case .value(let r) where r != .orderedSame:
                return descending ? r == .orderedDescending : r == .orderedAscending
            case .value:
                break
            }
            let byName = compareNames(a.name, b.name, locale: locale)
            if byName != .orderedSame {
                // 按名称排时跟着正 / 倒序走；按别的排遇到并列时，名字一律正序（和访达一样）
                if order == .name && reversed { return byName == .orderedDescending }
                return byName == .orderedAscending
            }
            return a.index < b.index
        }
        return result.map(\.item)
    }

    private enum Primary {
        case value(ComparisonResult)
        /// 只有一边缺信息；关联值 = a 是不是缺的那边。
        case missing(Bool)
    }

    private static func plain<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    private static func compareOptional<T>(_ a: T?, _ b: T?, _ cmp: (T, T) -> ComparisonResult) -> Primary {
        switch (a, b) {
        case let (x?, y?): return .value(cmp(x, y))
        case (nil, nil): return .value(.orderedSame)
        case (nil, _): return .missing(true)
        case (_, nil): return .missing(false)
        }
    }
}
