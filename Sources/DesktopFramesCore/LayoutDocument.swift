import Foundation

/// 最近一次真实移动的撤销记录（持久化：应用重启后仍可撤销一次）。
public struct MoveUndoRecord: Codable, Equatable, Sendable {
    public var id: UUID
    /// 移动前的位置（撤销时把项目放回这里）。
    public var source: URL
    /// 移动后的当前位置（撤销时从这里取走）。
    public var destination: URL
    public var performedAt: Date
    /// “替换”时被移到废纸篓的旧文件（撤销时放回 destination）。
    public var replacedTrashURL: URL?

    public init(id: UUID = UUID(), source: URL, destination: URL, performedAt: Date = Date(), replacedTrashURL: URL? = nil) {
        self.id = id
        self.source = source
        self.destination = destination
        self.performedAt = performedAt
        self.replacedTrashURL = replacedTrashURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, destination, performedAt, replacedTrashURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try Self.decodeURL(from: c, key: .source)
        destination = try Self.decodeURL(from: c, key: .destination)
        performedAt = try c.decodeIfPresent(Date.self, forKey: .performedAt) ?? Date()
        if let raw = try c.decodeIfPresent(String.self, forKey: .replacedTrashURL),
           let url = URL(string: raw), url.isFileURL {
            replacedTrashURL = url
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source.absoluteString, forKey: .source)
        try c.encode(destination.absoluteString, forKey: .destination)
        try c.encode(performedAt, forKey: .performedAt)
        try c.encodeIfPresent(replacedTrashURL?.absoluteString, forKey: .replacedTrashURL)
    }

    private static func decodeURL(from c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> URL {
        let raw = try c.decode(String.self, forKey: key)
        // 只接受本地文件 URL（file://），拒绝 http:// 或自定义 scheme。
        guard let url = URL(string: raw), url.isFileURL else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "不是本地文件 URL: \(raw)")
        }
        return url
    }
}

/// 布局文件顶层文档。
///
/// JSON 形如 `{ "version": 1, "zones": [...], "lastMoveUndo": [...] }`。
public struct LayoutDocument: Codable, Equatable, Sendable {
    /// 当前布局格式版本。
    public static let currentVersion = 1

    public var version: Int
    public var zones: [Zone]
    /// 最近一次真实移动的撤销批次（一次拖放可能移动多项；可整体撤销一次）。
    /// 兼容旧格式：早期版本此处为单条对象，加载时自动包装成数组。
    public var lastMoveUndo: [MoveUndoRecord]?

    public init(zones: [Zone] = [], lastMoveUndo: [MoveUndoRecord]? = nil, version: Int = LayoutDocument.currentVersion) {
        self.version = version
        self.zones = zones
        self.lastMoveUndo = lastMoveUndo
    }

    private enum CodingKeys: String, CodingKey {
        case version, zones, lastMoveUndo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 缺失 version 视为早期手写布局（v0）：按当前语义读取 zones。
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        zones = try c.decodeIfPresent([Zone].self, forKey: .zones) ?? []
        if c.contains(.lastMoveUndo) {
            if let batch = try? c.decodeIfPresent([MoveUndoRecord].self, forKey: .lastMoveUndo) {
                lastMoveUndo = batch
            } else if let single = try? c.decode(MoveUndoRecord.self, forKey: .lastMoveUndo) {
                lastMoveUndo = [single]
            } else {
                lastMoveUndo = nil
            }
        } else {
            lastMoveUndo = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(zones, forKey: .zones)
        if let batch = lastMoveUndo, !batch.isEmpty {
            try c.encode(batch, forKey: .lastMoveUndo)
        }
    }
}
