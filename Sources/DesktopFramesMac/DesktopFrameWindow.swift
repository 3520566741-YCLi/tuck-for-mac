import AppKit

/// 分区窗口基类：无边框（折叠条）形态下也能成为 key 窗口，
/// 保证点击展开、菜单、下拉等交互与有边框窗口一致。
final class DesktopFrameWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// 双重保险：即使系统发出缩放请求（双击标题区 / 绿灯），分区也不放大到全屏。
    override func zoom(_ sender: Any?) {}
    override func performZoom(_ sender: Any?) {}
}
