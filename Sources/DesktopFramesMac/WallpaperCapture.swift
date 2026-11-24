import AppKit
import CoreGraphics
import ScreenCaptureKit
import DesktopFramesCore

/// 动态壁纸也能折射：只截“壁纸那一层窗口”。
///
/// 为什么需要它：Sequoia / Tahoe 的动态（航拍、实时渲染）壁纸，系统不把真实画面交给 App，
/// NSWorkspace 只给一张对不上的占位图。唯一能拿到屏幕上真实壁纸的办法是 ScreenCaptureKit。
///
/// 隐私和打扰底线：
/// - 默认关闭，只有用户在菜单里打开才会用，打开时才请求一次「录屏」权限；没权限就安静地不折射，绝不反复弹窗；
/// - 只截系统壁纸窗口本身（desktopIndependentWindow 过滤器），截不到任何 App 窗口、桌面图标或文件内容；
/// - 截图只在内存里，裁出分区后面那一小块用完即弃，从不写盘；
/// - 只在分区停下 / 改大小 / 切空间 / 换壁纸时截一张单帧（不是录屏流），静止时零耗电；
/// - 每次最多等 2 秒，超时或失败就放弃，并且 60 秒内不再试（卡死自愈，不拖累别的软件）。
enum WallpaperCapture {
    static let defaultsKey = "GlassCaptureWallpaper"

    /// 用户是否打开了「动态壁纸也折射」。
    @MainActor static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            if newValue, !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess() // 只在用户亲手打开开关时请求一次
                watchForPermission()
            }
            CaptureCache.shared.clear()
            RefractionState.shared.bump()
        }
    }

    /// 现在屏幕上的壁纸是不是读不到真实画面（动态 / 航拍壁纸只给占位图），需要截壁纸层才能折射。
    @MainActor static var wallpaperNeedsCapture: Bool {
        NSScreen.screens.contains { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return true }
            var isDir: ObjCBool = false
            return !url.isFileURL || ZoneWindowManager.isPlaceholderWallpaper(url)
                || !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || isDir.boolValue
        }
    }

    /// 选了「边缘拉伸 / 光栅」但现在的壁纸读不到、又没开截壁纸层：说清楚为什么看不到，一键打开。
    /// 返回 true = 用户选择打开了。
    @MainActor @discardableResult
    static func offerIfNeeded() -> Bool {
        guard wallpaperNeedsCapture, !(isEnabled && hasPermission) else { return false }
        let alert = NSAlert()
        alert.messageText = L("动态壁纸下要截壁纸层才看得到折射", "Dynamic wallpapers need wallpaper capture for refraction")
        alert.informativeText = L(
            "你现在用的是系统动态壁纸，系统不把它的真实画面交给 App，所以玻璃折射（边缘拉伸 / 光栅）没法显示。\n\n打开后 Tuck 只截壁纸那一层（截不到任何窗口、桌面图标和文件），只在内存里用、不存盘。需要在接下来的系统提示里允许「录屏」；如果系统提示“退出并重新打开”，点它即可。",
            "You're using a dynamic wallpaper, which macOS doesn't share with apps, so glass refraction can't be shown.\n\nWhen turned on, Tuck captures only the wallpaper layer (never windows, desktop icons or files), keeps it in memory only, and never saves it. Allow Screen Recording in the next system prompt; if macOS offers \u{201C}Quit & Reopen\u{201D}, click it.")
        alert.addButton(withTitle: L("打开（只截壁纸层）", "Turn On (wallpaper only)"))
        alert.addButton(withTitle: L("先不用", "Not Now"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if isEnabled, !hasPermission {
            // 之前打开过但没授权：系统不会再弹提示，直接带去设置页
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            watchForPermission()
        } else {
            isEnabled = true
        }
        return true
    }

    /// 请求权限后每 2 秒看一眼（最多 3 分钟），一拿到就让各分区重新算，不用等下次移动。
    @MainActor private static func watchForPermission() {
        permissionWatch?.invalidate()
        permissionTicks = 0
        let timer = Timer(timeInterval: 2, repeats: true) { t in
            let done: Bool = MainActor.assumeIsolated {
                permissionTicks += 1
                if CGPreflightScreenCaptureAccess() {
                    CaptureCache.shared.clear()
                    RefractionState.shared.bump()
                    return true
                }
                return permissionTicks >= 90
            }
            if done { t.invalidate() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionWatch = timer
    }

    @MainActor private static var permissionWatch: Timer?
    @MainActor private static var permissionTicks = 0

    /// 已经有录屏权限（只查不弹窗）。
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 截一张指定屏幕上壁纸层的整屏图（像素尺寸 = 屏幕点数 × scale）。失败返回 nil。
    static func capture(displayID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat) async -> CGImage? {
        if let cached = CaptureCache.shared.image(displayID: displayID) { return cached }
        guard CaptureCache.shared.mayTry(), hasPermission else { return nil }
        let image = await withTimeout(seconds: 2) {
            await captureNow(displayID: displayID, screenFrame: screenFrame, scale: scale)
        }
        if let image {
            CaptureCache.shared.store(image, displayID: displayID)
        } else {
            CaptureCache.shared.noteFailure()
        }
        return image
    }

    private static func captureNow(displayID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }),
              let window = wallpaperWindow(in: content.windows, display: display) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(screenFrame.width * scale)
        config.height = Int(screenFrame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 找这块屏幕上的系统壁纸窗口。实测 macOS 26/27：壁纸由 WindowManager 的「Wallpaper」窗口画，
    /// 层级比 desktopWindow 低一层（旧系统是 Dock / 壁纸进程，正好在 desktopWindow 层），所以放宽到 desktopWindow-2…desktopWindow；
    /// 「Fullscreen Backdrop」在 desktopWindow+1 也铺满屏，不在范围内，另外按名字再排除一次。只认在屏幕上、铺满这块屏的。
    static func wallpaperWindow(in windows: [SCWindow], display: SCDisplay) -> SCWindow? {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let priority: [String: Int] = [
            "com.apple.WindowManager": 0, "com.apple.wallpaper.agent": 1, "com.apple.WallpaperAgent": 1, "com.apple.dock": 2
        ]
        let candidates = windows.filter { w in
            guard let bundle = w.owningApplication?.bundleIdentifier, priority[bundle] != nil else { return false }
            let title = w.title ?? ""
            return w.isOnScreen
                && (desktopLevel - 2...desktopLevel).contains(w.windowLayer)
                && !title.localizedCaseInsensitiveContains("Backdrop")
                && abs(w.frame.width - display.frame.width) < 2
                && abs(w.frame.height - display.frame.height) < 2
                && abs(w.frame.minX - display.frame.minX) < 2
                && abs(w.frame.minY - display.frame.minY) < 2
        }
        return candidates.min { a, b in
            let pa = priority[a.owningApplication?.bundleIdentifier ?? ""] ?? 9
            let pb = priority[b.owningApplication?.bundleIdentifier ?? ""] ?? 9
            if pa != pb { return pa < pb }
            // 同一进程有多个：名字是 Wallpaper 的优先，其次层级高的（更靠近屏幕上实际看到的那层）
            let ta = a.title == "Wallpaper", tb = b.title == "Wallpaper"
            if ta != tb { return ta }
            return a.windowLayer > b.windowLayer
        }
    }

    /// 最多等 seconds 秒，到点就直接返回 nil，不等慢的那一路结束。
    /// （不用 withTaskGroup：它返回前要等所有子任务结束，截图卡住又不理会取消时，“超时”就形同虚设。）
    private static func withTimeout(seconds: Double, _ work: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        let gate = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let job = Task {
                let image = await work()
                if gate.claim() { continuation.resume(returning: image) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() {
                    job.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// 只让第一个到的结果生效（续体只能 resume 一次）。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 截图缓存：同一块屏幕 20 秒内复用（同时移动几个分区时只截一次）；失败后 60 秒内不再试。
final class CaptureCache: @unchecked Sendable {
    static let shared = CaptureCache()
    private let lock = NSLock()
    private var images: [CGDirectDisplayID: (image: CGImage, at: Date)] = [:]
    private var failedAt: Date?

    func clear() {
        lock.lock(); images.removeAll(); failedAt = nil; lock.unlock()
    }

    func image(displayID: CGDirectDisplayID) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let e = images[displayID], Date().timeIntervalSince(e.at) < 20 else {
            images[displayID] = nil
            return nil
        }
        return e.image
    }

    func store(_ image: CGImage, displayID: CGDirectDisplayID) {
        lock.lock(); images[displayID] = (image, Date()); failedAt = nil; lock.unlock()
        // 整屏截图几十 MB：过期后主动释放，不等下次用到
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 21) { [weak self] in self?.purgeExpired() }
    }

    private func purgeExpired() {
        lock.lock(); defer { lock.unlock() }
        images = images.filter { Date().timeIntervalSince($0.value.at) < 20 }
    }

    func mayTry() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let failedAt else { return true }
        return Date().timeIntervalSince(failedAt) > 60
    }

    func noteFailure() {
        lock.lock(); failedAt = Date(); lock.unlock()
    }
}
