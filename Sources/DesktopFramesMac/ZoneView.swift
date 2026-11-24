import DesktopFramesCore
import SwiftUI
import UniformTypeIdentifiers

/// 单个分区的 SwiftUI 内容：标题 + 更多操作 + 项目区（支持拖放、打开、快速查看、移除入口）。
/// 桌面窗口由 AppKit 的 ZoneWindowManager 创建，本视图只负责分区内部 UI。
struct ZoneView: View {
    let manager: ZoneWindowManager
    let zoneID: UUID
    @ObservedObject private var model: AppModel
    @State private var isDropTargeted = false
    /// 选中的项目（可多选：⌘ 点击加选，⇧ 点击连选）；点空白处 / 点别的地方就清空。
    @State private var selection: Set<UUID> = []
    /// ⇧ 连选的起点。
    @State private var anchorID: UUID?
    /// 正在被拖放悬停的文件夹 / 应用图标（高亮成访达那样的“可以放进去”）。
    @State private var dropTargetID: UUID?
    /// 拖动调整位置时的“预览顺序”（拖动中其它图标按它滑开让位；松手写回分区，取消就丢掉）。
    @State private var previewOrder: [UUID]?
    /// 正在被拖动的项目（在原位留一个半透明的占位）。
    @State private var draggingIDs: Set<UUID> = []
    /// 外面拖进来的文件正悬停在某个普通图标上（那里也算“放进分区”，分区描边要亮）。
    @State private var itemZoneTargeted = false
    /// 上一次让位时的指针位置和时间：让位动画期间别的图标会滑到不动的指针下面，
    /// 不加限制就会来回互换（抖动）。指针没真正移动时，短时间内不再让位。
    @State private var reorderGuard = ReorderGuard()
    /// 正在直接改名的项目（访达式：名字变成输入框，回车确认、Esc 取消）。
    @State private var renamingID: UUID?
    /// 自动排序结果的短时缓存（按种类 / 日期 / 大小排要读文件信息，别每次重画都读一遍）。
    @State private var sortCache = SortCache()

    /// 拖动调整位置时，其它图标让位的动画。
    /// 手感参照 iOS 主屏：短一点、几乎不回弹，让位跟手。
    private static let reorderSpring = Animation.spring(response: 0.24, dampingFraction: 0.86)
    /// 在文件夹图标正中间停多久算“放进文件夹”（秒）。
    private static let folderDwell: TimeInterval = 0.45
    /// 拖动时在图标上停多久才让位（秒）。
    private static let reorderHover: TimeInterval = 0.15
    /// 普通图标：只防一下“擦边路过”，基本跟手。
    private static let reorderHoverPlain: TimeInterval = 0.05
    @State private var showAppearancePanel = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject private var glass = GlassSettings.shared
    @ObservedObject private var transfers: TransferCenter

    init(manager: ZoneWindowManager, zoneID: UUID) {
        self.manager = manager
        self.zoneID = zoneID
        self._model = ObservedObject(wrappedValue: manager.model)
        self._transfers = ObservedObject(wrappedValue: manager.transfers)
    }

    private var zone: Zone? { model.zone(id: zoneID) }

    /// 展开卡片圆角。
    private static let expandedCornerRadius: CGFloat = 24
    /// 收起后薄条的圆角（半径 = 高度一半，两端是半圆）。
    static let collapsedCornerRadius: CGFloat = 18

    /// 液态玻璃的“液体”动画曲线（收起/展开内容侧）：带一点回弹的弹簧感缓出，
    /// 与 ZoneWindowManager.liquidCurve 控制点一致，窗口与内容同步。
    static let liquidMorph = Animation.timingCurve(0.22, 0.8, 0.24, 1.0, duration: ZoneWindowManager.morphDuration)

    var body: some View {
        let collapsed = zone?.appearance.collapsed ?? false
        let radius: CGFloat = collapsed ? Self.collapsedCornerRadius : Self.expandedCornerRadius
        ZStack {
            // 1) 苹果官方液态玻璃底板（macOS 26 NSGlassEffectView）：白色磨砂 + 系统受光高光，
            //    圆角由玻璃自身控制。官方玻璃本体近乎无色，分区色调用下面的极淡染色层给出（类控制中心着色）。
            GlassEffect(cornerRadius: radius, style: glass.style)
                .opacity(glassOpacity)
            // 1a) 折射层：边缘拉伸 / 光栅玻璃（读壁纸算一次，静止零耗电）；收起成胶囊时不画
            if let zone, !collapsed, glass.refraction != .off {
                RefractionLayer(zoneID: zoneID, frameKey: zone.frame, mode: glass.refraction, style: glass.style,
                                cornerRadius: radius, manager: manager)
                    // 边缘折射是玻璃本身的形状，不该跟着“玻璃透明度”一起变淡（调得很透时边缘就看不出来了）
                    .opacity(glass.refraction == .edge ? max(glassOpacity, 0.9) : glassOpacity)
                    .transition(.opacity)
            }
            if let zone {
                // 1b) 潘通淡染色：仅 16% 保持通透；白色选项 = 不染色（纯清透磨砂）。
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tintColor(for: zone.appearance.tint).opacity(tintWashAlpha(for: zone.appearance.tint)))
                    .allowsHitTesting(false)
            }
            // 本分区里拖动调整位置时不亮描边（那不是“放进分区”）
            if (isDropTargeted && manager.reorderDrag?.zoneID != zoneID) || itemZoneTargeted {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
            } else {
                // 玻璃边缘光学细节（受光高光 / 倒角 / 色散 / 颗粒，按菜单栏“边缘光效”）
                LidLitEdgeOverlay(edge: glass.edge, style: glass.style, cornerRadius: radius)
            }
            // 2) 内容与标题：与玻璃同层绘制（不用 .overlay，超矮窗口里内容也能渲染）
            if let zone {
                VStack(spacing: 0) {
                    header(zone)
                    if let t = transfers.active, t.zoneID == zone.id, !zone.appearance.collapsed {
                        transferBar(t)
                    }
                    if !zone.appearance.collapsed {
                        Divider().opacity(0.25)
                            .transition(.opacity)
                        // 内容只做淡入淡出；高度变化由外层玻璃高度动画负责
                        content(zone)
                            .transition(.opacity)
                    }
                }
                .shadow(color: .black.opacity(glass.style.textShadowAlpha), radius: 2, x: 0, y: 1)
                // 标题栏永远钉在窗口顶边：ZStack 默认垂直居中，收起 / 展开动画中窗口高度在变，
                // 内容一淡出，标题栏就会跳到中间再跟着滑回去，看起来就是在抖。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .environment(\.colorScheme, glass.style.colorScheme ?? systemColorScheme)
        // 玻璃的可见高度由 SwiftUI 动画驱动（窗口本身展开时一步到位、收起时动画结束后再缩），
        // 这样展开时不会出现“窗口变大那一帧旧内容贴在底部”的下沉闪动。
        .frame(height: collapsed ? Self.headerHeight : nil)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Self.liquidMorph, value: collapsed)
        // 不画 SwiftUI 阴影：折叠窗口与内容同尺寸，阴影会被窗口边界裁成方形框线。
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            // 本分区里拖动调整位置、松手在图标之间的空隙 / 空白处：按预览顺序保存
            if manager.reorderDrag?.zoneID == zoneID {
                commitReorder()
                return true
            }
            handleDrop(providers: providers)
            return true
        }
        // 折叠条：常态半透明“低调”，鼠标悬停后变实，方便阅读与点击。
        .opacity(collapsed ? (isHovering ? 1.0 : collapsedRestAlpha) : 1.0)
        .onHover { over in
            guard collapsed else { return }
            isHovering = over
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        // 点了别的窗口 / 桌面 / 别的分区：选中框消失（之前会一直挂着）
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == zoneID.uuidString else { return }
            clearSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            clearSelection()
        }
        .onAppear {
            let view = self
            manager.setKeyHandler(zoneID: zoneID) { event in view.handleKey(event) }
        }
        .onDisappear { manager.setKeyHandler(zoneID: zoneID, nil) }
    }

    private func clearSelection() {
        if !selection.isEmpty { selection = [] }
        anchorID = nil
    }

    /// 折叠条常态不透明度（未悬停）：让桌面更清爽，移上去才完全显现。
    private var collapsedRestAlpha: Double { 0.85 }

    /// 玻璃底板不透明度：展开时跟随用户调节（0.10–1.0），收起时固定满值（由外层悬停控制整体淡显）。
    private var glassOpacity: Double {
        guard let zone else { return 0.9 }
        if zone.appearance.collapsed { return 1.0 }
        return zone.appearance.opacity
    }

    // MARK: - 标题栏

    /// 标题栏：展开与收起共用同一行、同一组按钮、同一高度。
    /// 收起时只是窗口从下往上收到这一行的高度（一条薄胶囊），标题栏里每个元素的位置都不动，
    /// 只有箭头转 90°（向下 = 展开，向右 = 收起）。
    private func header(_ zone: Zone) -> some View {
        let collapsed = zone.appearance.collapsed
        return HStack(spacing: 6) {
            Button {
                manager.setCollapsed(zoneID: zone.id, collapsed: !collapsed)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .help(collapsed ? L("展开分区", "Expand zone") : L("收起分区", "Collapse zone"))

            Circle()
                .fill(tintColor(for: zone.appearance.tint))
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(.primary.opacity(0.20), lineWidth: 0.8))

            Text(zone.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture(count: 2) { manager.promptRename(zoneID: zone.id) }
                .help(L("双击重命名", "Double-click to rename"))

            Spacer(minLength: 4)

            Text(L("\(zone.items.count) 项", zone.items.count == 1 ? "1 item" : "\(zone.items.count) items"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                manager.toggleLock(zoneID: zone.id)
            } label: {
                Image(systemName: zone.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 12))
                    .foregroundStyle(zone.locked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(zone.locked ? L("已锁定位置，点击解锁", "Position locked, click to unlock") : L("锁定位置（防止误拖动/缩放）", "Lock position (no accidental moves or resizing)"))

            Button {
                showAppearancePanel = true
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showAppearancePanel, arrowEdge: .bottom) {
                AppearancePanel(zone: zone, model: model)
            }
            .help(L("外观设置（透明度 / 主题色）", "Appearance (opacity / tint)"))

            zoneMenu(zone)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
        .contentShape(Rectangle())
        // 收起时点条身空白处展开（展开时这个点击手势关闭）
        .gesture(
            TapGesture().onEnded { manager.setCollapsed(zoneID: zone.id, collapsed: false) },
            including: collapsed ? .all : .subviews
        )
        // 展开、收起都可以按住标题栏空白处拖动整个分区；锁定时不动（按钮优先，不受影响）
        .gesture(moveGesture(zone))
    }

    /// 拖动整个分区的手势（锁定时什么都不做）。
    private func moveGesture(_ zone: Zone) -> some Gesture {
        DragGesture(minimumDistance: 3).onChanged { value in
            manager.moveZone(zoneID: zone.id, translation: value.translation)
        }
    }

    /// 内容区空白处的拖动面：透明但可点，放在图标后面。
    private func dragSurface(_ zone: Zone) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(moveGesture(zone))
            // 点图标之间 / 下方的空白处：取消选择（和访达一样）
            .simultaneousGesture(TapGesture().onEnded { clearSelection() })
            // 空白处右键：粘贴、新建文件夹、显示方式（和在访达窗口空白处右键一样）
            .contextMenu { blankAreaMenu(zone) }
    }

    @ViewBuilder
    private func blankAreaMenu(_ zone: Zone) -> some View {
        if zone.kind == .folder {
            Button(L("新建文件夹", "New Folder")) { startNewFolder(in: zone) }
        }
        Button(L("粘贴项目", "Paste Item")) { manager.pasteIntoZone(zone.id) }
        Divider()
        Button(zone.viewMode == .icon ? L("图标视图 ✓", "Icon View ✓") : L("图标视图", "Icon View")) {
            model.setViewMode(zoneID: zone.id, mode: .icon)
        }
        Button(zone.viewMode == .list ? L("列表视图 ✓", "List View ✓") : L("列表视图", "List View")) {
            model.setViewMode(zoneID: zone.id, mode: .list)
        }
        Divider()
        sortMenus(zone)
        if zone.kind == .folder, let url = zone.backingFolderURL {
            Divider()
            Button(L("在访达中显示关联文件夹", "Show Folder in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func startNewFolder(in zone: Zone) {
        guard let id = manager.newFolder(in: zone.id) else { return }
        selection = [id]
        anchorID = id
        beginRename(id)
    }

    // MARK: - 直接改名

    private func renameBinding(for item: ZoneItem) -> RenameState? {
        guard renamingID == item.id else { return nil }
        return RenameState(initial: item.url.lastPathComponent, isFolder: item.kind == .folder) { newName in
            renamingID = nil
            if let newName { manager.renameItem(item, to: newName) }
        }
    }

    private func beginRename(_ id: UUID) {
        guard let zone, zone.kind != .app, zone.items.contains(where: { $0.id == id }) else { return }
        // 分区所在 App 平时不在前台：先把它和这个分区窗口叫到前面，输入框才接得住键盘
        NSApp.activate(ignoringOtherApps: true)
        renamingID = id
    }

    /// 移动进度：细进度条 + 取消按钮（只在本分区有移动任务时出现）。
    private func transferBar(_ t: TransferCenter.Active) -> some View {
        HStack(spacing: 8) {
            Text(t.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: t.fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
            Button(L("取消", "Cancel")) { manager.cancelTransfer(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .transition(.opacity)
    }

    /// 标题栏高度 = 收起后薄条的高度（与 ZoneWindowManager.collapsedWindowHeight 一致）。
    static let headerHeight: CGFloat = 36

    /// 更多菜单（两态共用）。
    private func zoneMenu(_ zone: Zone) -> some View {
        Menu {
            Button(L("重命名…", "Rename…")) { manager.promptRename(zoneID: zone.id) }
            Divider()
            Button {
                model.setViewMode(zoneID: zone.id, mode: .list)
            } label: {
                Label(zone.viewMode == .list ? L("列表视图 ✓", "List View ✓") : L("列表视图", "List View"), systemImage: "list.bullet")
            }
            Button {
                model.setViewMode(zoneID: zone.id, mode: .icon)
            } label: {
                Label(zone.viewMode == .icon ? L("图标视图 ✓", "Icon View ✓") : L("图标视图", "Icon View"), systemImage: "square.grid.2x2")
            }
            sortMenus(zone)
            Divider()
            Menu(L("窗口大小", "Window Size")) {
                Button(L("小（320×220）", "Small (320×220)")) { manager.resizeZone(zoneID: zone.id, size: CGSize(width: 320, height: 220)) }
                Button(L("中（420×300）", "Medium (420×300)")) { manager.resizeZone(zoneID: zone.id, size: CGSize(width: 420, height: 300)) }
                Button(L("大（560×440）", "Large (560×440)")) { manager.resizeZone(zoneID: zone.id, size: CGSize(width: 560, height: 440)) }
                Divider()
                Text(L("提示：拖动窗口边缘/右下角可自由缩放", "Tip: drag an edge or the bottom-right corner to resize"))
            }
            Divider()
            if zone.kind == .folder, let url = zone.backingFolderURL {
                Button(L("在访达中显示关联文件夹", "Show Folder in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button(L("清理失效入口", "Clean Up Broken Shortcuts")) {
                let removed = manager.purgeNow()
                if removed > 0 {
                    manager.inform(title: L("已清理", "Cleaned up"), text: L("移除了 \(removed) 个已不存在项目的入口。", "Removed \(removed) shortcut(s) to items that no longer exist."))
                }
            }
            Divider()
            Button(L("删除分区…", "Delete Zone…"), role: .destructive) { manager.promptDelete(zoneID: zone.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("更多操作", "More"))
    }

    // MARK: - 项目区

    @ViewBuilder
    private func content(_ zone: Zone) -> some View {
        if zone.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(emptyHint(for: zone))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(moveGesture(zone))
        } else {
            switch zone.viewMode {
            case .list:
                listContent(zone)
            case .icon:
                iconContent(zone)
            }
        }
    }

    /// 按预览顺序排好的项目（没有预览时就是分区里保存的顺序）。
    private func displayedItems(_ zone: Zone) -> [ZoneItem] {
        guard let previewOrder else { return orderedItems(zone) }
        let byID = Dictionary(zone.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = previewOrder.compactMap { byID[$0] }
        let shown = Set(previewOrder)
        result.append(contentsOf: zone.items.filter { !shown.contains($0.id) })
        return result
    }

    private func listContent(_ zone: Zone) -> some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(displayedItems(zone)) { item in
                        ItemRowView(
                            item: item,
                            isSelected: selection.contains(item.id),
                            isDropTarget: dropTargetID == item.id,
                            tags: FinderTags.dotColors(for: item.url),
                            rename: renameBinding(for: item)
                        )
                        .opacity(draggingIDs.contains(item.id) ? 0.35 : 1)
                        // 改名时不盖交互层：点输入框就是编辑文字
                        .overlay { if renamingID != item.id { interaction(for: item, in: zone, list: true) } }
                    }
                }
                .animation(Self.reorderSpring, value: previewOrder)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                .background(dragSurface(zone))
            }
        }
    }

    private func iconContent(_ zone: Zone) -> some View {
        GeometryReader { geo in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92), spacing: 6, alignment: .top)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(displayedItems(zone)) { item in
                        IconCellView(
                            item: item,
                            isSelected: selection.contains(item.id),
                            isDropTarget: dropTargetID == item.id,
                            tags: FinderTags.dotColors(for: item.url),
                            rename: renameBinding(for: item)
                        )
                        // 被拖走的图标在原位留一个淡淡的占位，别的图标绕着它让位
                        .opacity(draggingIDs.contains(item.id) ? 0.3 : 1)
                        .scaleEffect(draggingIDs.contains(item.id) ? 0.92 : 1)
                        .overlay { if renamingID != item.id { interaction(for: item, in: zone, list: false) } }
                    }
                }
                .animation(Self.reorderSpring, value: previewOrder)
                .animation(.easeOut(duration: 0.15), value: draggingIDs)
                .padding(8)
                // 内容至少铺满可见高度：图标之间 / 周围 / 下方的空白处都能按住拖动分区、点一下取消选择；
                // 按在图标上就是图标自己的操作（选中 / 打开 / 拖动文件）
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                .background(dragSurface(zone))
            }
        }
    }

    /// 分区里的项目按当前排序方式排好（手动排列 = 保存的顺序）。只是显示顺序，不改任何文件。
    private func orderedItems(_ zone: Zone) -> [ZoneItem] {
        guard zone.isAutoSorted, zone.items.count > 1 else { return zone.items }
        return sortCache.sorted(zone)
    }

    /// “排序方式”和“整理方式”两个子菜单（访达同款）。
    /// 排序方式：一直按它排，新放进来的项目自动出现在该在的位置，不能手动拖动；选“无”回到原来的手动排列。
    /// 整理方式：只排一次，之后还能手动拖动（只在“无”时出现，和访达一样）。
    @ViewBuilder
    private func sortMenus(_ zone: Zone) -> some View {
        Menu(L("排序方式", "Sort By")) {
            ForEach(ZoneSortOrder.allCases, id: \.self) { order in
                Button(zone.sortOrder == order ? "\(order.displayName) ✓" : order.displayName) {
                    model.setSortOrder(zoneID: zone.id, order: order)
                }
                if order == .manual { Divider() }
            }
            if zone.isAutoSorted {
                Divider()
                Button(zone.sortReversed ? L("倒序 ✓", "Reverse Order ✓") : L("倒序", "Reverse Order")) {
                    model.setSortReversed(zoneID: zone.id, reversed: !zone.sortReversed)
                }
            }
        }
        if !zone.isAutoSorted {
            Menu(L("整理方式", "Clean Up By")) {
                ForEach(ZoneSortOrder.allCases.filter { $0 != .manual }, id: \.self) { order in
                    Button(order.displayName) {
                        withAnimation(Self.reorderSpring) { model.arrangeOnce(zoneID: zone.id, by: order) }
                    }
                }
            }
        }
    }

    // MARK: - 访达式交互（选中 / 打开 / 拖出 / 拖进文件夹 / 右键）

    /// 当前选中项（按分区里的顺序）。
    private func selectedItems(in zone: Zone) -> [ZoneItem] {
        orderedItems(zone).filter { selection.contains($0.id) }
    }

    /// 动作作用的对象：点在已选中的项目上 = 整组选中项；否则只是这一个。
    private func targets(for item: ZoneItem, in zone: Zone) -> [ZoneItem] {
        selection.contains(item.id) ? selectedItems(in: zone) : [item]
    }

    private func press(_ item: ZoneItem, in zone: Zone, flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchorID = item.id
        } else if flags.contains(.shift),
                  let anchorID,
                  case let shown = orderedItems(zone),
                  let a = shown.firstIndex(where: { $0.id == anchorID }),
                  let b = shown.firstIndex(where: { $0.id == item.id }) {
            // 按眼睛看到的顺序连选（自动排序时和保存的顺序不一样）
            selection.formUnion(shown[min(a, b)...max(a, b)].map(\.id))
        } else if !selection.contains(item.id) {
            selection = [item.id]
            anchorID = item.id
        }
    }

    private func clickUp(_ item: ZoneItem, flags: NSEvent.ModifierFlags) {
        // 普通单击（没拖动）：在多选里也收窄为只选这一个
        guard !flags.contains(.command), !flags.contains(.shift) else { return }
        if selection != [item.id] { selection = [item.id] }
        anchorID = item.id
    }

    private func interaction(for item: ZoneItem, in zone: Zone, list: Bool) -> FinderItemInteraction {
        let manager = self.manager
        let zoneID = zone.id
        let snapshot = zone
        // 回调里一律读分区的最新内容：刚保存完新顺序时，这里捕获的 zone 可能还是旧的，
        // 拿旧顺序开始下一次拖动会把刚排好的顺序又写回去。
        let current = { self.zone ?? snapshot }
        // “正中间”：图标视图是图标那块（格子上半部分的中间），列表视图是这一行的中间一条
        let center = list
            ? CGRect(x: 0, y: 0.25, width: 1, height: 0.5)
            : CGRect(x: 0.22, y: 0.38, width: 0.56, height: 0.56)
        return FinderItemInteraction(
            centerRegion: center,
            image: IconCache.icon(for: item.url),
            callbacks: .init(
                press: { flags in press(item, in: current(), flags: flags) },
                clickUp: { flags in clickUp(item, flags: flags) },
                doubleClick: {
                    let all = targets(for: item, in: current())
                    manager.openItems(all.map(\.url))
                },
                dragURLs: {
                    if !selection.contains(item.id) {
                        selection = [item.id]
                        anchorID = item.id
                    }
                    return targets(for: item, in: current()).map(\.url)
                },
                dragWillBegin: { urls in
                    let ids = Set(targets(for: item, in: current()).map(\.id))
                    manager.reorderDrag = .init(zoneID: zoneID, itemIDs: ids)
                    draggingIDs = ids
                    // 从眼睛看到的顺序开始（自动排序时不是保存的顺序），拖动中图标不会先跳一下
                    previewOrder = orderedItems(current()).map(\.id)
                    // 不在这里恢复桌面原图标：拖出玻璃框之前它都还“在框里”，桌面上不该冒出来
                    manager.beginItemDrag(urls)
                },
                menu: { itemMenu(for: item, in: current()) },
                dragOver: { urls, mask, dwell in dragOver(item, in: current(), urls: urls, mask: mask, dwell: dwell) },
                performDrop: { urls, mask in performDrop(on: item, in: current(), urls: urls, mask: mask) },
                dragExited: {
                    if dropTargetID == item.id { dropTargetID = nil }
                    if itemZoneTargeted { itemZoneTargeted = false }
                },
                dragEnded: { endReorderDrag() },
                dragMoved: { point in manager.itemDragMoved(to: point) },
                serviceURLs: { targets(for: item, in: current()).map(\.url) }
            )
        )
    }

    private func isDropContainer(_ item: ZoneItem) -> Bool {
        item.kind == .folder || item.kind == .application
    }

    private func setDropTarget(_ id: UUID?) {
        if dropTargetID != id { dropTargetID = id }
    }

    /// 拖动悬停在某个图标上。
    /// - 本分区里拖动：普通图标 / 文件夹边缘 = 调整位置（拖动的图标挪到这里，别的让开）；
    ///   文件夹正中间停一会儿 = 放进文件夹（高亮）。
    /// - 从外面拖来：文件夹 / 应用 = 立即放进去 / 用它打开（和访达一样）；普通图标 = 放进这个分区。
    private func dragOver(_ item: ZoneItem, in zone: Zone, urls: [URL], mask: NSDragOperation, dwell: TimeInterval?) -> NSDragOperation {
        let ownDrag = manager.reorderDrag?.zoneID == zone.id
        if ownDrag {
            if draggingIDs.contains(item.id) { // 指针在自己的占位上：保持现状
                reorderGuard.hoverID = nil
                setDropTarget(nil)
                return .move
            }
            if isDropContainer(item), let dwell {
                // 在文件夹正中间：先别让位，停够时间就变成“放进去”
                if dwell >= Self.folderDwell, let op = manager.dropOperation(for: urls, onto: item.url, mask: mask) {
                    setDropTarget(item.id)
                    return op.dragOperation
                }
                reorderGuard.hoverID = nil
                setDropTarget(nil)
                return .move
            }
            setDropTarget(nil)
            // 自动排序时顺序由排序决定，不让位（和访达一样，松手后图标回到原位）
            if zone.isAutoSorted { return .move }
            // 像手机桌面：在某个图标上停一下才让位（文件夹 / 应用约 0.15 秒，普通图标几乎立刻）。只是路过（比如去文件夹正中间时
            // 先经过它的边缘）不会把它挤走。
            let now = Date()
            if reorderGuard.hoverID != item.id {
                reorderGuard.hoverID = item.id
                reorderGuard.hoverSince = now
                return .move
            }
            let wait = isDropContainer(item) ? Self.reorderHover : Self.reorderHoverPlain
            guard now.timeIntervalSince(reorderGuard.hoverSince) >= wait else { return .move }
            moveDragged(before: item, in: zone)
            return .move
        }
        if isDropContainer(item) {
            let op = manager.dropOperation(for: urls, onto: item.url, mask: mask)
            setDropTarget(op == nil ? nil : item.id)
            if let op { return op.dragOperation }
        }
        // 外面拖来的、落在普通图标上：等同于放进这个分区
        setDropTarget(nil)
        if !itemZoneTargeted { itemZoneTargeted = true }
        return zone.kind == .folder ? .move : .copy
    }

    private func performDrop(on item: ZoneItem, in zone: Zone, urls: [URL], mask: NSDragOperation) -> Bool {
        let into = dropTargetID == item.id
        setDropTarget(nil)
        itemZoneTargeted = false
        let ownDrag = manager.reorderDrag?.zoneID == zone.id
        if ownDrag && !into {
            commitReorder()
            return true
        }
        if into || (!ownDrag && isDropContainer(item)) {
            if ownDrag { previewOrder = nil } // 放进文件夹：不改顺序，被移走的项目稍后自己消失
            return manager.performItemDrop(urls: urls, onto: item.url, mask: mask, zoneID: zone.id)
        }
        manager.drop(urls: urls, into: zone.id)
        return true
    }

    /// 把正在拖的项目（可能是一组）挪到 target 的位置：从前往后拖就放到它后面，从后往前就放到它前面。
    private func moveDragged(before target: ZoneItem, in zone: Zone) {
        let pointer = NSEvent.mouseLocation
        if let last = reorderGuard.lastAt,
           Date().timeIntervalSince(last) < 0.4,
           hypot(pointer.x - reorderGuard.lastPoint.x, pointer.y - reorderGuard.lastPoint.y) < 8 {
            return
        }
        var order = previewOrder ?? zone.items.map(\.id)
        guard let targetIndex = order.firstIndex(of: target.id),
              let firstDragged = order.firstIndex(where: { draggingIDs.contains($0) }) else { return }
        let moving = order.filter { draggingIDs.contains($0) }
        order.removeAll { draggingIDs.contains($0) }
        guard var insert = order.firstIndex(of: target.id) else { return }
        if firstDragged < targetIndex { insert += 1 }
        order.insert(contentsOf: moving, at: min(insert, order.count))
        if order != previewOrder {
            previewOrder = order
            reorderGuard.lastAt = Date()
            reorderGuard.lastPoint = pointer
        }
    }

    /// 松手在本分区里：按预览顺序保存。
    private func commitReorder() {
        if let order = previewOrder, zone?.isAutoSorted != true {
            model.reorderItems(zoneID: zoneID, orderedIDs: order)
        }
        previewOrder = nil
    }

    /// 拖动结束（放到别处 / 取消也会走到这里）：没保存的预览顺序丢掉，占位恢复。
    private func endReorderDrag() {
        reorderGuard.lastAt = nil
        reorderGuard.hoverID = nil
        if manager.reorderDrag?.zoneID == zoneID { manager.reorderDrag = nil }
        manager.endItemDrag()
        previewOrder = nil
        draggingIDs = []
        setDropTarget(nil)
    }

    /// 右键菜单（右键没选中的项目时先只选它，和访达一样）。
    /// 顺序和访达一致：打开 / 打开方式 → 移到废纸篓 → 简介、改名、压缩、复制、替身、快速查看、拷贝 → 共享 → 标签；
    /// 最后是 Tuck 自己的：在访达中显示、移出分区（仅移除入口）。系统“服务 / 快速操作”由系统追加在最底下。
    private func itemMenu(for item: ZoneItem, in zone: Zone) -> NSMenu {
        if !selection.contains(item.id) {
            selection = [item.id]
            anchorID = item.id
        }
        let all = targets(for: item, in: zone)
        let urls = all.map(\.url)
        let manager = self.manager
        let zoneID = zone.id
        let single = all.count == 1
        let name = item.url.lastPathComponent
        let canEditFiles = zone.kind != .app // 应用分区只放应用入口：不在这里改名 / 复制 / 压缩应用
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(L("打开", "Open")) { manager.openItems(urls) })
        if !all.contains(where: { $0.kind == .application }), let openWith = manager.openWithMenu(for: urls) {
            let item = NSMenuItem(title: L("打开方式", "Open With"), action: nil, keyEquivalent: "")
            item.submenu = openWith
            menu.addItem(item)
        }
        // 右键文件夹：把剪贴板里的文件粘贴进去（访达同款）
        if single, item.kind == .folder, !ZoneWindowManager.pasteboardFileURLs().isEmpty {
            menu.addItem(ClosureMenuItem(L("粘贴项目", "Paste Item")) { manager.paste(intoFolder: item.url, zoneID: zoneID) })
        }
        menu.addItem(.separator())
        let trash = ClosureMenuItem(L("移到废纸篓", "Move to Trash")) { manager.trashItems(all, zoneID: zoneID) }
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        trash.keyEquivalent = "\u{8}"
        trash.keyEquivalentModifierMask = [.command]
        menu.addItem(trash)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("显示简介", "Get Info"), keyEquivalent: "i") { manager.showInfo(urls) })
        if single && canEditFiles {
            let rename = ClosureMenuItem(L("重新命名", "Rename")) { beginRename(item.id) }
            menu.addItem(rename)
        }
        if canEditFiles {
            menu.addItem(ClosureMenuItem(single ? L("压缩“\(name)”", "Compress “\(name)”") : L("压缩 \(all.count) 个项目", "Compress \(all.count) Items")) {
                manager.compressItems(all, zoneID: zoneID)
            })
            menu.addItem(ClosureMenuItem(L("复制", "Duplicate"), keyEquivalent: "d") { manager.duplicateItems(all, zoneID: zoneID) })
            menu.addItem(ClosureMenuItem(L("制作替身", "Make Alias")) { manager.makeAliasItems(all, zoneID: zoneID) })
        }
        menu.addItem(ClosureMenuItem(L("快速查看", "Quick Look")) { manager.quickLookItems(urls) })
        menu.addItem(ClosureMenuItem(single ? L("拷贝“\(name)”", "Copy “\(name)”") : L("拷贝 \(all.count) 个项目", "Copy \(all.count) Items"), keyEquivalent: "c") {
            manager.copyToPasteboard(urls)
        })
        menu.addItem(.separator())
        // 系统标准“共享…”（AirDrop、信息、邮件、备忘录……）
        let picker = NSSharingServicePicker(items: urls.map { $0 as NSURL })
        let share = picker.standardShareMenuItem
        share.title = L("共享…", "Share…")
        menu.addItem(share)
        menu.addItem(.separator())
        let labels = NSWorkspace.shared.fileLabels
        var applied = Set<Int>()
        for index in FinderTags.menuOrder where labels.indices.contains(index) {
            if all.allSatisfy({ FinderTags.tagNames(of: $0.url).contains(labels[index]) }) { applied.insert(index) }
        }
        let swatches = NSMenuItem()
        swatches.view = TagSwatchMenuView(applied: applied) { index in manager.toggleTag(labelIndex: index, on: urls) }
        menu.addItem(swatches)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("在访达中显示", "Show in Finder")) { manager.revealItem(item.url) })
        // 只有文件夹分区里的文件是“真的在这里”，才提供这两个菜单移动；任何分区都可以直接拖到文件夹上移动。
        if zone.kind == .folder {
            menu.addItem(ClosureMenuItem(L("移到桌面…", "Move to Desktop…")) { performItemAction(.moveToDesktop, item: item, zone: zone) })
            menu.addItem(ClosureMenuItem(L("移到其它文件夹…", "Move to Another Folder…")) { performItemAction(.moveToFolder, item: item, zone: zone) })
        }
        let removeTitle = all.count > 1 ? L("移出分区（仅移除 \(all.count) 个入口）", "Remove from Zone (just the \(all.count) shortcuts)") : L("移出分区（仅移除入口）", "Remove from Zone (just the shortcut)")
        menu.addItem(ClosureMenuItem(removeTitle) {
            for target in all { manager.removeItem(id: target.id, from: zoneID) }
        })
        return menu
    }

    /// 分区窗口在前台时的按键：空格快速查看、⌘O / ⌘↓ 打开、⌘A 全选、⌘C 拷贝（可在访达里粘贴）、Esc 取消选择。
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let zone, !zone.appearance.collapsed else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let picked = selectedItems(in: zone)
        switch (flags, event.keyCode, chars) {
        case ([], 49, _): // 空格
            guard !picked.isEmpty else { return false }
            manager.quickLookItems(picked.map(\.url))
            return true
        case ([], 53, _): // Esc
            clearSelection()
            return true
        case ([.command], _, "o"), ([.command], 125, _): // ⌘O / ⌘↓
            guard !picked.isEmpty else { return false }
            manager.openItems(picked.map(\.url))
            return true
        case ([.command], _, "a"):
            selection = Set(zone.items.map(\.id))
            return true
        case ([.command], _, "c"):
            guard !picked.isEmpty else { return false }
            manager.copyToPasteboard(picked.map(\.url))
            return true
        case ([.command], _, "v"): // ⌘V 粘贴到分区
            guard !ZoneWindowManager.pasteboardFileURLs().isEmpty else { return false }
            manager.pasteIntoZone(zone.id)
            return true
        case ([.command], 51, _): // ⌘⌫ 移到废纸篓
            guard !picked.isEmpty else { return false }
            manager.trashItems(picked, zoneID: zone.id)
            clearSelection()
            return true
        case ([.command], _, "i"): // ⌘I 显示简介
            guard !picked.isEmpty else { return false }
            manager.showInfo(picked.map(\.url))
            return true
        case ([.command], _, "d"): // ⌘D 复制
            guard !picked.isEmpty, zone.kind != .app else { return false }
            manager.duplicateItems(picked, zoneID: zone.id)
            return true
        case ([.command, .control], _, "a"): // ⌃⌘A 制作替身
            guard !picked.isEmpty, zone.kind != .app else { return false }
            manager.makeAliasItems(picked, zoneID: zone.id)
            return true
        case ([.command, .shift], _, "n"): // ⇧⌘N 新建文件夹（文件分区）
            guard zone.kind == .folder else { return false }
            startNewFolder(in: zone)
            return true
        case ([.command], _, "z"): // ⌘Z 撤销上次移动（含移到废纸篓）
            guard !model.undoBatch.isEmpty else { return false }
            manager.undoLastMove(nil)
            return true
        case ([], 36, _), ([], 76, _): // 回车：改名（访达同款）
            guard picked.count == 1 else { return false }
            beginRename(picked[0].id)
            return true
        default:
            return false
        }
    }

    private func emptyHint(for zone: Zone) -> String {
        switch zone.kind {
        case .folder: return L("从访达拖入文件或文件夹\n将移动到分区关联的真实文件夹", "Drag files or folders here from Finder\nThey move into the zone's real folder")
        case .virtual: return L("从访达拖入文件或文件夹\n只保存入口，不改变原路径", "Drag files or folders here from Finder\nOnly a shortcut is kept; nothing moves")
        case .app: return L("从访达拖入应用（.app）\n保存快捷入口", "Drag apps (.app) here from Finder\nKeeps a shortcut")
        }
    }

    // MARK: - 动作

    private func performItemAction(_ action: ItemAction, item: ZoneItem, zone: Zone) {
        switch action {
        case .moveToDesktop: manager.moveItemToDesktop(item: item, zone: zone)
        case .moveToFolder: manager.moveItemToFolder(item: item, zone: zone)
        }
    }

    // MARK: - 拖放

    private func handleDrop(providers: [NSItemProvider]) {
        // 异步加载 URL，避免在主线程同步等待 NSItemProvider 回调造成死锁（拖入时卡死）。
        let holder = ProviderHolder(providers: providers)
        let zoneID = self.zoneID
        let manager = self.manager
        Task {
            var urls: [URL] = []
            for provider in holder.providers {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await MainActor.run {
                manager.drop(urls: urls, into: zoneID)
            }
        }
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var resolved: URL?
                if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolved = url
                }
                continuation.resume(returning: resolved)
            }
        }
    }
}

/// 把非 Sendable 的 [NSItemProvider] 装入可安全跨任务传递的容器（仅供异步加载拖放内容）。
private final class ProviderHolder: @unchecked Sendable {
    let providers: [NSItemProvider]
    init(providers: [NSItemProvider]) {
        self.providers = providers
    }
}

// MARK: - 外观

/// 可选主题色：潘通 2018–2025 八个年度代表色 + 纯白。
struct TintOption: Identifiable {
    let id: String
    let name: String
    let hex: UInt32

    var color: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    static let all: [TintOption] = [
        TintOption(id: "ultraViolet18", name: "Ultra Violet · 2018", hex: 0x5F4B8B),
        TintOption(id: "livingCoral19", name: "Living Coral · 2019", hex: 0xFF6F61),
        TintOption(id: "classicBlue20", name: "Classic Blue · 2020", hex: 0x0F4C81),
        TintOption(id: "illuminating21", name: "Illuminating · 2021", hex: 0xF5DF4D),
        TintOption(id: "veryPeri22", name: "Very Peri · 2022", hex: 0x6667AB),
        TintOption(id: "vivaMagenta23", name: "Viva Magenta · 2023", hex: 0xBB2649),
        TintOption(id: "peachFuzz24", name: "Peach Fuzz · 2024", hex: 0xFFBE98),
        TintOption(id: "mochaMousse25", name: "Mocha Mousse · 2025", hex: 0xA47864),
        TintOption(id: "white", name: L("白色（清透无染色）", "White (clear, no tint)"), hex: 0xFFFFFF),
    ]

    static let defaultID = "white"

    /// 按标识取色；兼容旧存档里的系统色标识（映射到最接近的潘通色），未知标识回退默认色。
    static func option(for id: String?) -> TintOption {
        guard let id else { return all.first { $0.id == defaultID }! }
        if let hit = all.first(where: { $0.id == id }) { return hit }
        let legacy: String
        switch id {
        case "systemBlue": legacy = "classicBlue20"
        case "systemPurple": legacy = "ultraViolet18"
        case "systemRed": legacy = "vivaMagenta23"
        case "systemOrange": legacy = "livingCoral19"
        case "systemPink": legacy = "peachFuzz24"
        case "systemTeal": legacy = "veryPeri22"
        case "systemGreen": legacy = "mochaMousse25"
        case "graphite", "systemGray": legacy = "white"
        default: legacy = defaultID
        }
        return all.first { $0.id == legacy }!
    }
}

/// 外观设置浮层：透明度滑杆 + 快捷档位 + 主题色。
private struct AppearancePanel: View {
    let zone: Zone
    let model: AppModel

    /// 快捷档位：10%–90%，每 10% 一档。
    private static let opacityLevels: [Double] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("外观", "Appearance"))
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 10) {
                Text(L("透明度", "Opacity"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { zone.appearance.opacity },
                        set: { model.setOpacity(zoneID: zone.id, opacity: $0) }
                    ),
                    in: 0.10...1.0
                )
                .frame(width: 118)
                Text("\(Int((zone.appearance.opacity * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            // 快捷档位：10%–90%
            VStack(alignment: .leading, spacing: 4) {
                Text(L("快捷档位", "Presets"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 4) {
                    ForEach(Self.opacityLevels, id: \.self) { level in
                        let current = abs(zone.appearance.opacity - level) < 0.005
                        Button {
                            model.setOpacity(zoneID: zone.id, opacity: level)
                        } label: {
                            Text("\(Int((level * 100).rounded()))%")
                                .font(.system(size: 10))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(current ? Color.accentColor : Color.primary.opacity(0.08))
                                )
                                .foregroundStyle(current ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help(current ? L("当前档位", "Current") : L("设为 \(Int((level * 100).rounded()))%", "Set to \(Int((level * 100).rounded()))%"))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("主题色（潘通流行色）", "Tint (Pantone Color of the Year)"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(TintOption.all) { option in
                        Button {
                            model.setTint(zoneID: zone.id, tint: option.id)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 18, height: 18)
                                if TintOption.option(for: zone.appearance.tint).id == option.id {
                                    Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.6)
                                } else {
                                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                                }
                            }
                            .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help(option.name)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 230)
    }
}

/// 通过 tint 标识取主题色（Color；潘通色 / 旧存档系统色自动映射）。
private func tintColor(for tint: String?) -> Color {
    TintOption.option(for: tint).color
}

/// 玻璃上的潘通淡染色强度：白色 = 不染色（纯清透磨砂）；其余约 16%，既上色又不失通透。
private func tintWashAlpha(for tint: String?) -> Double {
    (tint == "white") ? 0 : 0.16
}

private enum ItemAction {
    case moveToDesktop, moveToFolder
}

/// 图标视图单元格：图标 + 名称（只负责外观；点击 / 拖动 / 右键由盖在上面的 FinderItemInteraction 处理）。
private struct IconCellView: View {
    let item: ZoneItem
    let isSelected: Bool
    let isDropTarget: Bool
    var tags: [Color] = []
    var rename: RenameState?

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: IconCache.icon(for: item.url))
                .resizable()
                .frame(width: 44, height: 44)
                .padding(2)
                .background(
                    // 访达式选中：图标后面一块浅灰圆角底
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.14) : .clear)
                )
            if let rename {
                RenameField(state: rename, fontSize: 11, centered: true)
                    .frame(height: 18)
                    .padding(.horizontal, 2)
            } else {
                // 颜色标签色点在名字前面（访达图标视图同款）
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    TagDots(colors: tags)
                    Text(item.displayName ?? item.url.lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    // 访达式选中：名字套一块强调色圆角底
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isSelected ? Color.accentColor : .clear)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            // 拖东西悬停在文件夹上：整格高亮，表示“松手就放进去”
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.28) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}

/// 单行项目：图标 + 名称（交互同上）。
private struct ItemRowView: View {
    let item: ZoneItem
    let isSelected: Bool
    let isDropTarget: Bool
    var tags: [Color] = []
    var rename: RenameState?

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: item.url))
                .resizable()
                .frame(width: 16, height: 16)
            if let rename {
                RenameField(state: rename, fontSize: 12, centered: false)
                    .frame(height: 18)
            } else {
                Text(item.displayName ?? item.url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
                // 列表视图：色点在行尾（访达列表同款）
                TagDots(colors: tags)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor : (isDropTarget ? Color.accentColor.opacity(0.28) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}

/// 正在改名的项目：初始名字 + 结束回调（nil = 取消）。
struct RenameState {
    let initial: String
    let isFolder: Bool
    let finish: (String?) -> Void
}

/// 访达式改名输入框：出现时自动获得焦点，只选中“名字”部分（不选扩展名）；
/// 回车确认，Esc 取消，点到别处也算确认（和访达一样）。
private struct RenameField: NSViewRepresentable {
    let state: RenameState
    let fontSize: CGFloat
    let centered: Bool

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: state.initial)
        field.font = .systemFont(ofSize: fontSize)
        field.alignment = centered ? .center : .left
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.focusRingType = .exterior
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.wantsLayer = true
        field.layer?.cornerRadius = 3
        field.delegate = context.coordinator
        field.setAccessibilityLabel(L("新名称", "New name"))
        let initial = state.initial
        let isFolder = state.isFolder
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            // 文件只选中扩展名前面的部分；文件夹选全部
            let ext = (initial as NSString).pathExtension
            let length = (isFolder || ext.isEmpty) ? (initial as NSString).length : (initial as NSString).length - (ext as NSString).length - 1
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: max(0, length))
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.state = state
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var state: RenameState
        private var finished = false

        init(state: RenameState) { self.state = state }

        private func finish(_ value: String?) {
            guard !finished else { return }
            finished = true
            let callback = state.finish
            // 等这次键盘 / 焦点事件走完再改布局（输入框会随之消失）
            DispatchQueue.main.async { callback(value) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(nil)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(textView.string)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // 点到别处 / 窗口失焦：按访达的习惯当作确认
            finish((obj.object as? NSTextField)?.stringValue)
        }
    }
}

/// 文件图标缓存：避免每次 SwiftUI 重算 body 都向系统取图标。
/// 上限 256 个，内存紧张时系统可自动回收（NSCache）。
@MainActor
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    /// 系统图标带 16–1024px 多个尺寸，解码后很占内存；分区里最大只显示 44pt，
    /// 这里画成一张 64pt（Retina 下 128px）的位图只留这一份。
    private static let side: CGFloat = 64

    private static func downsampled(_ icon: NSImage) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return icon }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return icon }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = downsampled(NSWorkspace.shared.icon(forFile: url.path))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 拖动让位的防抖状态（引用类型：改它不触发重绘）。
private final class ReorderGuard {
    var lastAt: Date?
    var lastPoint: CGPoint = .zero
    /// 正在停留的图标和开始停留的时刻。
    var hoverID: UUID?
    var hoverSince = Date.distantPast
}

/// 自动排序结果的缓存：分区内容 / 排序方式没变、并且不到 2 秒，就直接用上次排好的顺序。
/// 过 2 秒重新读一次文件信息，这样文件被修改后（按修改日期 / 大小排）位置会自己更新。
final class SortCache {
    private var signature: [AnyHashable] = []
    private var order: [UUID] = []
    private var at = Date.distantPast

    func sorted(_ zone: Zone) -> [ZoneItem] {
        var sig: [AnyHashable] = [zone.sortOrder, zone.sortReversed]
        sig.append(contentsOf: zone.items.map { [AnyHashable($0.id), AnyHashable($0.url), AnyHashable($0.displayName)] as [AnyHashable] })
        // 名称 / 种类不会因为文件内容变化而变（种类要查系统类型说明，上千个文件要 0.2 秒）：内容没变就一直用缓存
        let fresh = zone.sortOrder == .name || zone.sortOrder == .kind || Date().timeIntervalSince(at) < 2
        if sig == signature, fresh {
            let byID = Dictionary(zone.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let cached = order.compactMap { byID[$0] }
            if cached.count == zone.items.count { return cached }
        }
        let result = ZoneSorter.sorted(zone.items, by: zone.sortOrder, reversed: zone.sortReversed)
        signature = sig
        order = result.map(\.id)
        at = Date()
        return result
    }
}
