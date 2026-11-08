import Foundation

/// 布局加载结果。损坏文件会被隔离（重命名保留），应用从空布局启动并提示恢复备份。
public struct ZoneStoreLoadResult: Sendable {
    public let document: LayoutDocument
    /// 本次是否从损坏/无法解析的文件中恢复（返回空文档）。
    public let recoveredFromCorruption: Bool
    /// 被隔离的损坏文件位置（若有）。
    public let quarantinedFile: URL?
    /// 给用户的提示（例如“布局来自更新版本，已备份，从空布局开始”）。
    public let notice: String?

    public init(document: LayoutDocument, recoveredFromCorruption: Bool, quarantinedFile: URL?, notice: String?) {
        self.document = document
        self.recoveredFromCorruption = recoveredFromCorruption
        self.quarantinedFile = quarantinedFile
        self.notice = notice
    }
}

/// 一份布局备份的元信息。
public struct BackupInfo: Identifiable, Equatable, Sendable {
    public let url: URL
    public let date: Date
    public var id: URL { url }
}

/// ZoneStore：加载、校验、保存分区布局 JSON；损坏隔离；写入前滚动备份（只保留最近五份）。
///
/// 非线程安全类型，约定在主线程/串行上下文中使用；测试各自使用独立临时目录，互不干扰。
public final class ZoneStore {
    public let layoutFile: URL
    public let backupsDirectory: URL
    private let fileManager: FileManager

    /// 保留的最近备份份数。
    public static let backupLimit = 5

    /// 两次备份的最小间隔（秒）。0 = 每次保存都备份（测试用默认值）；
    /// App 设为 10 分钟，避免拖几下窗口就把好备份全部轮换掉。
    public var minimumBackupInterval: TimeInterval = 0
    /// 检测到布局损坏后暂停删除旧备份，直到用户恢复或重启，确保损坏前的好备份不被冲掉。
    public private(set) var pruningSuspended = false

    public init(layoutFile: URL, backupsDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.layoutFile = layoutFile
        self.fileManager = fileManager
        let dir = backupsDirectory ?? layoutFile
            .deletingLastPathComponent()
            .appendingPathComponent("Layout Backups", isDirectory: true)
        self.backupsDirectory = dir
    }

    /// 使用默认位置：`~/Library/Application Support/<name>/layout.json`。
    /// 开发/测试便利：`name` 以 `/` 开头时视为绝对目录，直接使用（不依赖 Application Support）。
    public convenience init(appSupportSubdirectory name: String = "Tuck", fileManager: FileManager = .default) {
        if name.hasPrefix("/") {
            let dir = URL(fileURLWithPath: name, isDirectory: true)
            self.init(layoutFile: dir.appendingPathComponent("layout.json"), fileManager: fileManager)
            return
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent(name, isDirectory: true)
        self.init(layoutFile: dir.appendingPathComponent("layout.json"), fileManager: fileManager)
    }

    // MARK: - 加载

    /// 加载布局。不会抛错：所有失败路径都返回可用的空文档，并给出恢复标记。
    public func load() -> ZoneStoreLoadResult {
        if !fileManager.fileExists(atPath: layoutFile.path) {
            return ZoneStoreLoadResult(document: LayoutDocument(), recoveredFromCorruption: false, quarantinedFile: nil, notice: nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: layoutFile)
        } catch {
            pruningSuspended = true
            let quarantine = quarantineCorruptFile(errorNote: "无法读取文件：\(error.localizedDescription)")
            return .init(document: LayoutDocument(), recoveredFromCorruption: true, quarantinedFile: quarantine, notice: "布局文件无法读取，已隔离并保留原文件。")
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(LayoutDocument.self, from: data)

            if doc.version > LayoutDocument.currentVersion {
                // 更新版本应用写出的文件：不破坏原文件，复制一份到备份目录后从空布局开始。
                let copy = archiveUnknownVersion(doc.version)
                return .init(
                    document: LayoutDocument(),
                    recoveredFromCorruption: false,
                    quarantinedFile: nil,
                    notice: copy == nil
                        ? "布局由更新版本 (v\(doc.version)) 写出，本次从空布局开始，原文件已保留。"
                        : "布局由更新版本 (v\(doc.version)) 写出，已存档为 \(copy?.lastPathComponent ?? "")，本次从空布局开始。"
                )
            }

            return .init(document: doc, recoveredFromCorruption: false, quarantinedFile: nil, notice: nil)
        } catch {
            pruningSuspended = true
            let quarantine = quarantineCorruptFile(errorNote: "JSON 解析失败：\(error.localizedDescription)")
            return .init(document: LayoutDocument(), recoveredFromCorruption: true, quarantinedFile: quarantine, notice: "布局文件损坏，已隔离并保留原文件；可通过“恢复最近备份”找回。")
        }
    }

    // MARK: - 保存

    /// 保存布局：先滚动备份现有文件（保留最近五份），再原子写入。
    public func save(_ document: LayoutDocument) throws {
        try fileManager.createDirectory(at: layoutFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let newest = availableBackups().first?.date
        let due = newest.map { Date().timeIntervalSince($0) >= minimumBackupInterval } ?? true
        if fileManager.fileExists(atPath: layoutFile.path), due {
            do {
                let backupURL = backupsDirectory.appendingPathComponent(Self.backupFileName(for: Date()))
                try fileManager.copyItem(at: layoutFile, to: backupURL)
                try pruneBackups(keeping: Self.backupLimit)
            } catch {
                // 备份失败不阻断主写入；让用户可感知？此处选择继续（备份是尽力而为）。
                // 主文件仍会更新，失败原因可在此扩展日志。
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: layoutFile, options: .atomic)
    }

    // MARK: - 备份

    /// 按时间倒序列出最近备份（最多 backupLimit 份）。
    public func availableBackups() -> [BackupInfo] {
        let contents = (try? fileManager.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("layout-backup-") }
            .compactMap { url -> BackupInfo? in
                guard let date = Self.backupDate(from: url.lastPathComponent) else { return nil }
                return BackupInfo(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    /// 从指定备份恢复：校验可解析后写回主布局文件。
    public func restoreBackup(_ backup: BackupInfo) throws -> LayoutDocument {
        let data = try Data(contentsOf: backup.url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(LayoutDocument.self, from: data)
        try save(doc)
        return doc
    }

    // MARK: - 内部工具

    /// 隔离损坏文件：改名保留在同一目录，避免下次启动再次触发。
    private func quarantineCorruptFile(errorNote: String) -> URL? {
        let stamp = Self.timestampString(for: Date())
        let target = layoutFile.deletingLastPathComponent()
            .appendingPathComponent("layout.corrupt-\(stamp).json")
        do {
            try fileManager.moveItem(at: layoutFile, to: target)
            return target
        } catch {
            // 只读目录等情况：尽力而为，无法隔离就原样留下。
            return nil
        }
    }

    /// 更新版本文件存档（复制到备份目录，带版本号前缀），不删除原文件。
    private func archiveUnknownVersion(_ version: Int) -> URL? {
        let stamp = Self.timestampString(for: Date())
        let target = backupsDirectory.appendingPathComponent("layout-future-v\(version)-\(stamp).json")
        do {
            try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: layoutFile, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// 删除多余备份，只保留最新的 `keeping` 份。
    private func pruneBackups(keeping: Int) throws {
        guard !pruningSuspended else { return }
        let backups = availableBackups()
        guard backups.count > keeping else { return }
        for backup in backups.dropFirst(keeping) {
            try? fileManager.removeItem(at: backup.url)
        }
    }

    // MARK: - 命名 / 时间

    /// 备份文件名：layout-backup-<yyyyMMdd-HHmmss-SSS>-<4位随机>.json
    /// 时间戳后追加随机后缀，避免同一毫秒内连续保存产生同名文件。
    private static func backupFileName(for date: Date) -> String {
        let suffix = UUID().uuidString.prefix(4)
        return "layout-backup-\(timestampString(for: date))-\(suffix).json"
    }

    private static func timestampString(for date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private static func backupDate(from name: String) -> Date? {
        // 文件名: layout-backup-<yyyyMMdd-HHmmss-SSS>-<随机>.json
        // 时间戳为定长 19 字符，前缀 "layout-backup-" 为 14 字符。
        let prefix = "layout-backup-"
        let body = name.dropFirst(prefix.count).prefix(19)
        guard body.count == 19 else { return nil }
        return Self.formatter.date(from: String(body))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()
}
