import Foundation

/// 分区类型。
///
/// - `folder`: 文件分区，关联一个真实文件夹（backingFolderPath）。拖入的新项目默认执行真实移动。
/// - `virtual`: 虚拟分区，只保存项目入口 URL，拖入绝不更改源文件路径。
/// - `app`: 应用分区，保存常用 App 的入口，不复制或移动 App。
///
/// 与 `docs/…/2026-09-05-desktop-organizer-design.md` 的 JSON `kind` 取值保持一致。
public enum ZoneKind: String, Codable, Sendable, CaseIterable {
    case folder
    case virtual
    case app

    public var displayName: String {
        switch self {
        case .folder: return "文件分区"
        case .virtual: return "虚拟分区"
        case .app: return "应用分区"
        }
    }

    /// 是否默认执行真实文件移动（仅 folder 分区）。
    public var movesFilesByDefault: Bool { self == .folder }
}

/// 分区内容显示方式。
public enum ZoneViewMode: String, Codable, Sendable, CaseIterable {
    case list
    case icon

    public var displayName: String {
        switch self {
        case .list: return "列表"
        case .icon: return "图标"
        }
    }
}

/// 分区内单个项目的类型。
public enum ZoneItemKind: String, Codable, Sendable, CaseIterable {
    case file
    case folder
    case application
}

/// 分区在屏幕上的位置与尺寸（AppKit 全局坐标，原点在主屏左下角，y 向上）。
public struct ZoneFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 420, height: Double = 300) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 分区外观（首版只落库，UI 逐项应用）。
public struct ZoneAppearance: Codable, Equatable, Sendable {
    public var tint: String
    public var opacity: Double
    public var collapsed: Bool

    public init(tint: String = "white", opacity: Double = 0.9, collapsed: Bool = false) {
        self.tint = tint
        self.opacity = opacity
        self.collapsed = collapsed
    }
}

/// 分区内的项目入口。url 始终是绝对 file URL；folder 分区经真实移动后指向关联文件夹内的新位置，
/// virtual / app 分区始终指向源位置。
public struct ZoneItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var kind: ZoneItemKind
    /// 可选展示名；为空时由 App 层从文件名推导。
    public var displayName: String?
    /// 真实移动前的原始位置（folder 分区拖入时记录；退出“放回桌面原位置”据此还原）。
    /// 旧存档 / 虚拟 / 应用分区为 nil。
    public var movedFrom: URL?
    /// 真实移入文件分区时记录的文件编号（inode）。退出归位前核对，编号不符（已被换成别的文件）就不动。
    public var movedFileNumber: UInt64?

    public init(id: UUID = UUID(), url: URL, kind: ZoneItemKind, displayName: String? = nil, movedFrom: URL? = nil) {
        self.id = id
        self.url = url
        self.kind = kind
        self.displayName = displayName
        self.movedFrom = movedFrom
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, kind, displayName, movedFrom, movedFileNumber
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        guard let urlString = try c.decodeIfPresent(String.self, forKey: .url) else {
            throw DecodingError.keyNotFound(
                CodingKeys.url,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "item 缺少 url")
            )
        }
        // 只接受本地文件 URL：被篡改的布局里若写入 https:// 或自定义 scheme，
        // 双击时会被 NSWorkspace 当网页 / 外部 App 打开。
        guard let url = URL(string: urlString), url.isFileURL else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.url,
                in: c,
                debugDescription: "不是本地文件 url: \(urlString)"
            )
        }
        self.url = url
        kind = try c.decodeIfPresent(ZoneItemKind.self, forKey: .kind) ?? .file
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        if let movedFromString = try c.decodeIfPresent(String.self, forKey: .movedFrom),
           let movedFromURL = URL(string: movedFromString), movedFromURL.isFileURL {
            self.movedFrom = movedFromURL
        }
        movedFileNumber = try? c.decodeIfPresent(UInt64.self, forKey: .movedFileNumber)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url.absoluteString, forKey: .url)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(movedFrom?.absoluteString, forKey: .movedFrom)
        try c.encodeIfPresent(movedFileNumber, forKey: .movedFileNumber)
    }
}

/// 一个桌面分区。
public struct Zone: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ZoneKind
    public var frame: ZoneFrame
    /// 分区所在的显示器标识（App 层生成，如 CGDirectDisplayID 或显示器名）。
    public var screenID: String
    public var appearance: ZoneAppearance
    /// 标签页（阶段 B 使用，首版为空数组，仍按设计文档落库）。
    public var tabs: [String]
    /// 保留的安全书签字段：本应用当前非沙盒，实际以 backingFolderPath 为准；该字段为空。
    public var backingFolderBookmark: String?
    /// folder 分区关联的真实文件夹绝对路径。
    public var backingFolderPath: String?
    /// 是否锁定位置（锁定后窗口不可拖动/缩放）。
    public var locked: Bool
    /// 内容显示方式（列表 / 图标）。
    public var viewMode: ZoneViewMode
    public var items: [ZoneItem]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ZoneKind,
        frame: ZoneFrame = ZoneFrame(),
        screenID: String = "",
        appearance: ZoneAppearance = ZoneAppearance(),
        tabs: [String] = [],
        backingFolderBookmark: String? = nil,
        backingFolderPath: String? = nil,
        locked: Bool = false,
        viewMode: ZoneViewMode = .list,
        items: [ZoneItem] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.frame = frame
        self.screenID = screenID
        self.appearance = appearance
        self.tabs = tabs
        self.backingFolderBookmark = backingFolderBookmark
        self.backingFolderPath = backingFolderPath
        self.locked = locked
        self.viewMode = viewMode
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, frame, screenID, appearance, tabs
        case backingFolderBookmark, backingFolderPath, locked, viewMode, items, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "分区"
        kind = try c.decodeIfPresent(ZoneKind.self, forKey: .kind) ?? .virtual
        frame = try c.decodeIfPresent(ZoneFrame.self, forKey: .frame) ?? ZoneFrame()
        screenID = try c.decodeIfPresent(String.self, forKey: .screenID) ?? ""
        appearance = try c.decodeIfPresent(ZoneAppearance.self, forKey: .appearance) ?? ZoneAppearance()
        tabs = try c.decodeIfPresent([String].self, forKey: .tabs) ?? []
        backingFolderBookmark = try c.decodeIfPresent(String.self, forKey: .backingFolderBookmark)
        backingFolderPath = try c.decodeIfPresent(String.self, forKey: .backingFolderPath)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        viewMode = try c.decodeIfPresent(ZoneViewMode.self, forKey: .viewMode) ?? .list
        // 逐条容错：某一条损坏 / 不是本地文件 URL 时只丢掉这一条，不让整个布局被判为损坏。
        items = (try c.decodeIfPresent([LossyItem].self, forKey: .items) ?? []).compactMap(\.value)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(frame, forKey: .frame)
        try c.encode(screenID, forKey: .screenID)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(tabs, forKey: .tabs)
        try c.encodeIfPresent(backingFolderBookmark, forKey: .backingFolderBookmark)
        try c.encodeIfPresent(backingFolderPath, forKey: .backingFolderPath)
        try c.encode(locked, forKey: .locked)
        try c.encode(viewMode, forKey: .viewMode)
        try c.encode(items, forKey: .items)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// 是否为虚拟/应用等不改动源文件的分区。
    public var isEntryOnly: Bool { kind != .folder }

    /// folder 分区关联文件夹的 URL（非沙盒下由路径解析）。
    public var backingFolderURL: URL? {
        guard let path = backingFolderPath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// 解码单个条目失败时返回 nil，而不是让整个数组失败。
private struct LossyItem: Decodable {
    let value: ZoneItem?
    init(from decoder: Decoder) throws {
        value = try? ZoneItem(from: decoder)
    }
}
