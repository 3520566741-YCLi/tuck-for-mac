import AppKit
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey）：不需要辅助功能权限，也不监听其它按键。
/// 只注册一个组合键：⌃⌥D = 切换“偷看”（分区临时浮到所有窗口最上层）。
@MainActor
final class PeekHotKey {
    static let display = "⌃⌥D"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void
    private static weak var current: PeekHotKey?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// 注册；失败（被别的 App 占用）时返回 false，菜单项仍可用。
    @discardableResult
    func register() -> Bool {
        unregister()
        PeekHotKey.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PeekHotKey.current?.action() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard status == noErr else { return false }

        let id = EventHotKeyID(signature: OSType(0x4446_4D43), id: 1) // 'DFMC'
        let modifiers = UInt32(controlKey | optionKey)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_D), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if result != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
