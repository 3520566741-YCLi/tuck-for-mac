import AppKit

// 菜单栏 App 入口（LSUIElement 风格：无 Dock 图标，仅菜单栏）。
let app = NSApplication.shared

// 单实例保护：如果已有一个打包版实例在运行（相同 bundle id），
// 激活它并退出自己 —— 避免反复点击 Dock/重复打开造成桌面分区窗口重复。
if let bundleID = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .first(where: { $0.processIdentifier != NSRunningApplication.current.processIdentifier }) {
    // 已在运行（只在强制多开时会走到这里；从访达 / 启动台打开由系统发“重新打开”给已在运行的实例）
    other.activate()
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
