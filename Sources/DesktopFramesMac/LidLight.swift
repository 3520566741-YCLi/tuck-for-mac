import AppKit
import Combine
import IOKit.hid

/// 「光随屏幕角度」：读 MacBook 屏幕铰链角度传感器，推拉屏幕时让玻璃边缘的高光顺着边缘滑动
/// （像 iPhone 歪手机时的反光）。
///
/// 为什么不是陀螺仪：Mac 没有陀螺仪；M 系列里的加速度计要管理员权限才能读，不适合常驻软件。
/// 铰链角度传感器挂在 HID 总线上（Sensor 用途页 0x20 / 用途 0x8A，Apple 0x05AC / 0x8104），
/// 不需要任何权限。读取方式参考开源项目 LidAngleSensor（Apache-2.0）和 LidLab：Feature Report 1，
/// 第 1、2 字节是小端角度（0° 合上，约 140° 全开）。
///
/// 省电和不打扰别的软件：
/// - 屏幕不动时每秒只读一次（一次极小的 HID 读取），屏幕在动时才短暂提到每秒 30 次；
/// - 只在“边缘光效”不是原版、且开关打开时才运行；显示器睡眠时停下，醒来再继续；
/// - 读取放在后台串行队列，绝不卡主线程；连续读失败或读取卡住 → 自动停掉，过一会儿重新找传感器，
///   重试几次还不行就放弃（玻璃回到固定光，什么都不影响）；
/// - 只发布“高光偏移角度”，变化小于 0.3° 不刷新界面。
@MainActor
final class LidLight: ObservableObject {
    static let shared = LidLight()
    static let defaultsKey = "GlassLidLight"

    /// 高光沿边缘的偏移角度（度）：屏幕往后推 → 正，往前拉 → 负。没有传感器时一直是 0。
    @Published private(set) var offset: Double = 0
    /// 这台 Mac 能不能读到屏幕角度（菜单里据此决定是否可选）。
    private(set) var isAvailable = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) == nil || UserDefaults.standard.bool(forKey: Self.defaultsKey) } // bool(forKey:) 也认命令行 / defaults 写进来的 "NO" 字符串
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            refreshRunning()
        }
    }

    private let reader = LidAngleReader()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var lastAngle: Double?
    private var lastMovedAt: TimeInterval = 0
    private var smoothed: Double?
    private var failures = 0
    private var readInFlight = false
    private var readStartedAt: TimeInterval = 0
    private var retryCount = 0
    private var retryWork: DispatchWorkItem?
    private var screensAsleep = false
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []

    private static let idleInterval: TimeInterval = 1.0
    private static let activeInterval: TimeInterval = 1.0 / 30.0
    private static let stillness: TimeInterval = 1.5
    private static let maxRetries = 5

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LidLight.shared.screensAsleep = true; LidLight.shared.refreshRunning() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                LidLight.shared.screensAsleep = false
                LidLight.shared.retryCount = 0 // 醒来给传感器一次新机会
                LidLight.shared.refreshRunning()
            }
        })
    }

    /// 由外观设置驱动：边缘光效不是原版时才需要光随角度走。
    func setWanted(_ wanted: Bool) {
        wantsRunning = wanted
        refreshRunning()
    }

    private func refreshRunning() {
        if wantsRunning && isEnabled && !screensAsleep {
            start()
        } else {
            stop(resetOffset: !(wantsRunning && isEnabled))
        }
    }

    private func start() {
        guard timer == nil, retryWork == nil else { return }
        let queue = reader.queue
        let reader = self.reader
        queue.async {
            let ok = reader.open()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isAvailable = ok
                    guard ok else { self.scheduleRetry(); return }
                    self.failures = 0
                    self.schedule(Self.idleInterval)
                }
            }
        }
    }

    private func stop(resetOffset: Bool) {
        timer?.invalidate()
        timer = nil
        interval = 0
        retryWork?.cancel()
        retryWork = nil
        let reader = self.reader
        reader.queue.async { reader.close() }
        if resetOffset, offset != 0 { offset = 0 }
        lastAngle = nil
        smoothed = nil
    }

    private func schedule(_ newInterval: TimeInterval) {
        guard abs(newInterval - interval) > 0.0001 || timer == nil else { return }
        timer?.invalidate()
        interval = newInterval
        let t = Timer(timeInterval: newInterval, repeats: true) { _ in
            MainActor.assumeIsolated { LidLight.shared.tick() }
        }
        t.tolerance = newInterval * 0.2 // 允许系统合并唤醒，更省电
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if readInFlight {
            // 上一次读取 2 秒还没回来：传感器卡住了，停掉自愈
            if now - readStartedAt > 2 { selfHeal() }
            return
        }
        readInFlight = true
        readStartedAt = now
        let reader = self.reader
        reader.queue.async {
            let angle = reader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { LidLight.shared.handle(angle) }
            }
        }
    }

    private func handle(_ angle: Double?) {
        readInFlight = false
        guard timer != nil else { return }
        guard let angle, angle >= 0, angle <= 180 else {
            failures += 1
            if failures >= 5 { selfHeal() }
            return
        }
        failures = 0
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastAngle, abs(angle - last) >= 0.5 { lastMovedAt = now }
        lastAngle = angle
        // 平滑一下，避免传感器噪声让高光抖
        let s = smoothed.map { $0 + (angle - $0) * 0.45 } ?? angle
        smoothed = s
        // 110°（平时最常用的开合角度）为中间；每偏 1° 屏幕，高光沿边缘移 0.9°，最多 ±40°
        let target = max(-40, min(40, (s - 110) * 0.9))
        if abs(target - offset) >= 0.3 { offset = target }
        schedule(now - lastMovedAt < Self.stillness ? Self.activeInterval : Self.idleInterval)
    }

    private func selfHeal() {
        stop(resetOffset: false)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryCount < Self.maxRetries else { return } // 放弃：保持固定光，直到下次唤醒
        retryCount += 1
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                LidLight.shared.retryWork = nil
                LidLight.shared.refreshRunning()
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }
}

/// 底层传感器读取（只在自己的串行队列上用）。
final class LidAngleReader: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.github.tuckformac.tuck.lid-angle", qos: .utility)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer = [UInt8](repeating: 0, count: 8)

    func open() -> Bool {
        if device != nil { return true }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            kIOHIDPrimaryUsagePageKey as String: 0x20,
            kIOHIDPrimaryUsageKey as String: 0x8A
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        for candidate in set {
            guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            device = candidate
            self.manager = manager
            if read() != nil { return true }
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
        }
        self.manager = nil
        return false
    }

    func read() -> Double? {
        guard let device else { return nil }
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buffer, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        return Double(UInt16(buffer[2]) << 8 | UInt16(buffer[1]))
    }

    func close() {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
    }
}
