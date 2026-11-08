import AppKit
import DesktopFramesCore

extension NSScreen {
    /// CGDirectDisplayID（AppKit 私有键 NSScreenNumber）。
    var dshDisplayID: UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// 转为纯值描述，供 FrameSanitizer 使用。
    var dshDescriptor: ScreenDescriptor {
        ScreenDescriptor(displayID: dshDisplayID, name: localizedName, frame: frame, visibleFrame: visibleFrame)
    }

    static var dshAll: [ScreenDescriptor] { NSScreen.screens.map(\.dshDescriptor) }
}
