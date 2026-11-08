import Foundation

/// 登录时自动启动：通过用户级 LaunchAgent（RunAtLoad）注册当前 App。
///
/// - 默认**关闭**：只有用户在菜单里打开后才写 plist。
/// - 只在 App 以 .app 包运行时注册（开发时直接跑二进制不会写开机项）。
/// - plist 里程序路径与当前 App 不一致时（App 被移动 / 重装）自动改写。
/// - 只删除自己写的、Label 匹配的 plist。
enum LaunchAtLogin {
    static let label = "io.github.tuckformac.tuck"
    /// v2 起使用新键：旧版“默认开启”的偏好不再沿用。
    static let preferenceKey = "LaunchAtLoginEnabled.v2"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? false
    }

    /// 启动时调用：让磁盘状态与偏好一致。
    static func syncWithDisk() {
        if isEnabled {
            register()
        } else {
            unregister()
        }
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        if enabled { register() } else { unregister() }
    }

    /// 只有打包好的 .app 才注册（路径指向 .app 内可执行文件）。
    private static var bundledExecutable: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.executablePath
    }

    static func register() {
        guard isEnabled, let executable = bundledExecutable,
              let dir = agentsDirectory, let url = plistURL else { return }
        if registeredProgram() == executable { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // 尽力而为：失败不阻断（用户仍可手动启动）
        }
    }

    static func unregister() {
        guard let url = plistURL, isOwnPlist(at: url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 已注册 plist 中的程序路径（没有或读不出时为 nil）。
    private static func registeredProgram() -> String? {
        guard let url = plistURL, let dict = readPlist(at: url) else { return nil }
        return (dict["ProgramArguments"] as? [String])?.first
    }

    private static func isOwnPlist(at url: URL) -> Bool {
        (readPlist(at: url)?["Label"] as? String) == label
    }

    private static func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return obj as? [String: Any]
    }

    private static var agentsDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL? {
        agentsDirectory?.appendingPathComponent("\(label).plist")
    }
}
