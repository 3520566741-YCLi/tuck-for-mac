import Foundation

/// 界面语言：系统首选语言是中文就用中文，否则用英文。
/// 环境变量 `TUCK_LANG=zh` / `TUCK_LANG=en` 可以强制指定（拍截图、测试用）。
public enum UILanguage {
    public static let isChinese: Bool = {
        if let forced = ProcessInfo.processInfo.environment["TUCK_LANG"]?.lowercased() {
            if forced.hasPrefix("zh") { return true }
            if forced.hasPrefix("en") { return false }
        }
        let first = Locale.preferredLanguages.first ?? "zh-Hans"
        return first.lowercased().hasPrefix("zh")
    }()
}

/// 界面文字：同时写中文和英文，按系统语言挑一个。新加界面文字一律用它。
/// UI text: write both Chinese and English; the system language picks one.
@inline(__always)
public func L(_ zh: String, _ en: String) -> String {
    UILanguage.isChinese ? zh : en
}
