import AppKit
import DesktopFramesCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var manager: ZoneWindowManager?
    private var loadNoticeShown = false
    private var peekHotKey: PeekHotKey?
    private var captureMenuItem: NSMenuItem?
    /// 「桌面上的新下载自动收进」子菜单的代理（菜单只弱引用代理，这里留住它）。
    private var collectMenuDelegate: CollectDownloadsMenu?
    private var termSource: DispatchSourceSignal?

    /// 已在运行时又从访达 / 启动台打开：系统发来“重新打开”，弹出菜单栏菜单回应。
    /// （只认系统事件，不再用任何进程都能发的全局通知。）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusMenu()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 开发/测试：可用绝对路径目录替换默认数据位置（见 ZoneStore.appSupportSubdirectory）。
        let dataDir = ProcessInfo.processInfo.environment["DESKTOPFRAMES_DATA_DIR"] ?? "Tuck"
        let store = ZoneStore(appSupportSubdirectory: dataDir)
        store.minimumBackupInterval = 600 // 备份最多每 10 分钟一份，避免好备份被很快轮换掉
        let manager = ZoneWindowManager(store: store)
        self.manager = manager
        // 分区里的文件右键菜单要列出系统“服务 / 快速操作”（和访达一样）：声明我们能往外送文件
        NSApp.registerServicesMenuSendTypes([.fileURL, FinderItemNSView.legacyFilenames], returnTypes: [])

        // 菜单栏图标
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
            button.setAccessibilityLabel(AppInfo.name)
        }
        item.menu = buildMenu(for: manager)
        statusItem = item

        // 被 kill（SIGTERM，例如注销 / 关机 / 活动监视器“退出”）时走正常退出流程，
        // 这样被 Tuck 隐藏的桌面原图标会先恢复显示。
        signal(SIGPIPE, SIG_IGN) // 看门狗先退出时，写管道不能把 Tuck 带崩
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            // 有对话框开着时 terminate 会被模态循环挡住：先关掉对话框再退出
            if NSApp.modalWindow != nil { NSApp.abortModal() }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        term.resume()
        termSource = term

        // 屏幕变化（外接屏拔掉 / 分辨率变化）时回收越界分区
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 启动恢复：按布局创建分区窗口
        manager.syncAllWindows()

        // 开机自启动：默认关闭；只有用户在菜单里打开过才注册（并修正为当前程序路径）。
        LaunchAtLogin.syncWithDisk()

        // 全局快捷键 ⌃⌥D：偷看（分区临时浮到最上层）
        let hotKey = PeekHotKey { [weak manager] in manager?.togglePeek(nil) }
        hotKey.register()
        peekHotKey = hotKey

        // 启动提示（损坏恢复 / 布局清洗）
        if let notice = manager.model.notice, !loadNoticeShown {
            loadNoticeShown = true
            manager.inform(title: L("布局已重置", "Layout reset"), text: notice)
        }
        // 上次退出自动归位的报告（如“已把 N 项放回桌面原位置”）
        if let notice = manager.consumePendingNotice() {
            manager.inform(title: L("上次退出时的提示", "From the last time Tuck quit"), text: notice)
        }
        if let report = manager.consumeLastRestoreReport() {
            manager.inform(title: L("已放回桌面", "Put back on the desktop"), text: report)
        }
    }

    /// 弹出菜单栏菜单（被再次打开时）。
    @objc private func showStatusMenu() {
        statusItem?.button?.performClick(nil)
    }

    /// 菜单栏模板图标：上面一条胶囊 + 下面一个圆角框（与 App 图标呼应），深浅色自动适配。
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 1.5, width: 14, height: 4), xRadius: 2, yRadius: 2).fill()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2.75, y: 7.75, width: 12.5, height: 7.5), xRadius: 2.5, yRadius: 2.5)
            frame.lineWidth = 1.5
            frame.stroke()
            NSBezierPath(roundedRect: NSRect(x: 5.5, y: 10, width: 2.5, height: 3), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 10, width: 2.5, height: 3), xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }

    /// 菜单栏：光随屏幕角度变化（没有角度传感器的 Mac 上打开也没影响，玻璃保持固定光）。
    @objc private func toggleLidLight(_ sender: NSMenuItem) {
        LidLight.shared.isEnabled.toggle()
        sender.state = LidLight.shared.isEnabled ? .on : .off
    }

    /// 菜单栏：动态壁纸也折射（只截壁纸层，要录屏权限；打开时才请求一次）。
    @objc private func toggleCaptureWallpaper(_ sender: NSMenuItem) {
        if !WallpaperCapture.isEnabled || !WallpaperCapture.hasPermission, WallpaperCapture.wallpaperNeedsCapture {
            WallpaperCapture.offerIfNeeded() // 先说清楚要什么权限、截什么
        } else {
            WallpaperCapture.isEnabled.toggle()
        }
        sender.state = WallpaperCapture.isEnabled ? .on : .off
    }

    /// 菜单栏：开机自启动开关。
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    /// 移动进行中要退出：先取消、等它清理完临时副本再退出（源文件始终完好）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        manager?.prepareToQuit() ?? .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出自动归位：把拖入文件分区的文件放回桌面原位置（可在菜单栏关闭）。
        manager?.restoreMovedFilesToOriginalPlaces()
        manager?.persistNow()
        manager?.restoreDesktopIcons()
        manager?.shutdown()
        peekHotKey?.unregister()
    }

    @objc private func screensDidChange(_ notification: Notification) {
        manager?.reflowAllWindows()
    }

    // MARK: - 菜单

    private func buildMenu(for manager: ZoneWindowManager) -> NSMenu {
        let root = NSMenu()

        // 新建分区
        let createItem = NSMenuItem(title: L("新建分区", "New Zone"), action: nil, keyEquivalent: "")
        let createMenu = NSMenu()
        createMenu.addItem(makeItem(L("普通分区（只放入口，不动文件）…", "Regular Zone (shortcuts only, files stay put)…"), #selector(ZoneWindowManager.newVirtualZone(_:)), manager))
        createMenu.addItem(makeItem(L("应用分区…", "App Zone…"), #selector(ZoneWindowManager.newAppZone(_:)), manager))
        createMenu.addItem(.separator())
        createMenu.addItem(makeItem(L("文件夹分区（拖入会真实移动文件）…", "Folder Zone (dropped files really move)…"), #selector(ZoneWindowManager.newFolderZone(_:)), manager))
        createMenu.addItem(makeItem(L("下载分区（浏览器直接下载到这里）…", "Download Zone (browsers download straight into it)…"), #selector(ZoneWindowManager.newDownloadZone(_:)), manager))
        createItem.submenu = createMenu
        root.addItem(createItem)

        // 玻璃：质感 / 折射 / 边缘都在每个分区标题栏的调色板里单独调；这里只留两个全局开关
        let glassItem = NSMenuItem(title: L("玻璃效果", "Glass Effects"), action: nil, keyEquivalent: "")
        let glassMenu = NSMenu()
        let glassHint = NSMenuItem(title: L("质感、折射、边缘：点分区标题栏的调色板，每个分区单独调", "Glass, refraction and edge: use each zone's palette button"), action: nil, keyEquivalent: "")
        glassHint.isEnabled = false
        glassMenu.addItem(glassHint)
        glassMenu.addItem(.separator())
        let captureItem = NSMenuItem(title: L("动态壁纸也折射（只截壁纸层，需录屏权限）", "Refract dynamic wallpapers too (captures only the wallpaper layer; needs Screen Recording)"), action: #selector(toggleCaptureWallpaper(_:)), keyEquivalent: "")
        captureItem.target = self
        captureMenuItem = captureItem
        captureItem.state = WallpaperCapture.isEnabled ? .on : .off
        glassMenu.addItem(captureItem)
        let lidItem = NSMenuItem(title: L("光随屏幕角度变化（推拉屏幕时高光会滑动）", "Light follows the lid angle (rim light slides as you tilt the screen)"), action: #selector(toggleLidLight(_:)), keyEquivalent: "")
        lidItem.target = self
        lidItem.state = LidLight.shared.isEnabled ? .on : .off
        glassMenu.addItem(lidItem)
        glassItem.submenu = glassMenu
        root.addItem(glassItem)

        // 在桌面上隐藏已收纳的原图标（默认开）
        let hideItem = NSMenuItem(title: L("在桌面上隐藏已收纳的原图标", "Hide Tucked Icons on the Desktop"), action: #selector(ZoneWindowManager.toggleHideOnDesktop(_:)), keyEquivalent: "")
        hideItem.target = manager
        hideItem.state = manager.isHideOnDesktopEnabled ? .on : .off
        manager.hideOnDesktopMenuItem = hideItem
        root.addItem(hideItem)
        // 新下载（「下载」文件夹 + 桌面）自动收进某个分区（默认关）
        let collectItem = NSMenuItem(title: L("新下载自动移进分区", "Move New Downloads Into"), action: nil, keyEquivalent: "")
        let collectMenu = NSMenu()
        collectMenu.autoenablesItems = false
        let collectDelegate = CollectDownloadsMenu(manager: manager)
        collectMenuDelegate = collectDelegate
        collectMenu.delegate = collectDelegate
        collectItem.submenu = collectMenu
        root.addItem(collectItem)
        // 「Tuck 分区」入口文件夹：被隐藏的桌面文件在别的软件的打开 / 上传窗口里从这里找
        let mirrorItem = NSMenuItem(title: L("在个人文件夹放「Tuck 分区」入口（上传文件时用）", "Keep a “Tuck Zones” folder in Home (for upload dialogs)"), action: #selector(ZoneWindowManager.toggleZoneMirror(_:)), keyEquivalent: "")
        mirrorItem.target = manager
        mirrorItem.state = manager.isZoneMirrorEnabled ? .on : .off
        root.addItem(mirrorItem)
        let openMirror = NSMenuItem(title: L("在访达中显示「Tuck 分区」", "Show “Tuck Zones” in Finder"), action: #selector(ZoneWindowManager.openZoneMirror(_:)), keyEquivalent: "")
        openMirror.target = manager
        openMirror.indentationLevel = 1
        root.addItem(openMirror)

        // 偷看：分区临时浮到最上层
        let peek = NSMenuItem(title: L("偷看分区（临时浮到最上层）  \(PeekHotKey.display)", "Peek at Zones (float on top for now)  \(PeekHotKey.display)"), action: #selector(ZoneWindowManager.togglePeek(_:)), keyEquivalent: "")
        peek.target = manager
        manager.peekMenuItem = peek
        root.addItem(peek)
        root.addItem(.separator())

        // 备份恢复
        let backupItem = NSMenuItem(title: L("恢复备份", "Restore Backup"), action: nil, keyEquivalent: "")
        let backupMenu = NSMenu()
        backupMenu.autoenablesItems = false
        manager.configureBackupSubmenu(backupMenu)
        backupItem.submenu = backupMenu
        root.addItem(backupItem)

        // 撤销上次真实移动（自动启用/禁用）
        // 不设快捷键：菜单打开时 ⌘Z 会被它接走并真实移动文件，容易误触
        let undo = NSMenuItem(title: L("撤销上次移动", "Undo Last Move"), action: #selector(ZoneWindowManager.undoLastMove(_:)), keyEquivalent: "")
        undo.target = manager
        manager.undoMenuItem = undo
        root.addItem(undo)

        // 安全网：任何收起的分区找不到/点不到时，从这里一键恢复
        let expandAll = NSMenuItem(
            title: L("展开全部收起的分区", "Expand All Collapsed Zones"),
            action: #selector(ZoneWindowManager.expandAllCollapsedZones(_:)),
            keyEquivalent: ""
        )
        expandAll.target = manager
        root.addItem(expandAll)

        // 清理失效入口（全局）
        let purge = NSMenuItem(title: L("清理失效入口…", "Clean Up Broken Shortcuts…"), action: #selector(ZoneWindowManager.purgeNowMenuAction(_:)), keyEquivalent: "")
        purge.target = manager
        root.addItem(purge)

        // 退出时自动归位开关（把拖入文件分区的文件放回桌面原位置）
        let restore = NSMenuItem(
            title: L("退出时自动把拖入的文件放回桌面原位置", "Put Dropped Files Back on the Desktop When Quitting"),
            action: #selector(ZoneWindowManager.toggleRestoreOnQuit(_:)),
            keyEquivalent: ""
        )
        restore.target = manager
        restore.state = manager.isRestoreOnQuitEnabled ? .on : .off
        manager.restoreOnQuitMenuItem = restore
        root.addItem(restore)

        // 开机自启动（登录后自动恢复桌面分区）
        let autostart = NSMenuItem(
            title: L("登录时自动启动", "Open at Login"),
            action: #selector(AppDelegate.toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        autostart.target = self
        autostart.state = LaunchAtLogin.isEnabled ? .on : .off
        root.addItem(autostart)

        // 关于（含构建时间，便于核对版本）
        let about = NSMenuItem(title: L("关于 \(AppInfo.name)…", "About \(AppInfo.name)…"), action: #selector(ZoneWindowManager.showAbout(_:)), keyEquivalent: "")
        about.target = manager
        root.addItem(about)

        root.addItem(.separator())
        let quit = NSMenuItem(title: L("退出 \(AppInfo.name)", "Quit \(AppInfo.name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        root.addItem(quit)
        return root
    }

    private func makeItem(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
