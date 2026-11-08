import Foundation

/// App 名称集中在这里（改名只改一处）。显示名取 Info.plist，开发时直接运行二进制则用默认值。
enum AppInfo {
    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Tuck"
    }

}
