// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesktopFramesMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DesktopFramesCore", targets: ["DesktopFramesCore"]),
        .executable(name: "DesktopFramesMac", targets: ["DesktopFramesMac"]),
        .executable(name: "TuckWatchdog", targets: ["TuckWatchdog"])
    ],
    targets: [
        // 纯逻辑核心：数据模型、布局存储、坐标修正、文件操作。
        // 与 UI 分离，便于用 swift test 自动验证。
        .target(name: "DesktopFramesCore"),
        // 菜单栏 App 本体（SwiftUI + AppKit 界面）。
        .executableTarget(
            name: "DesktopFramesMac",
            dependencies: ["DesktopFramesCore"]
        ),
        // 看门狗：Tuck 异常退出时恢复被隐藏的桌面原图标（只用 Darwin，极小）。
        .executableTarget(name: "TuckWatchdog"),
        .testTarget(
            name: "DesktopFramesCoreTests",
            dependencies: ["DesktopFramesCore"]
        )
    ]
)
