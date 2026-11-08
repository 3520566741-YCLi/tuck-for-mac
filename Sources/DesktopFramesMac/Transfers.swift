import DesktopFramesCore
import Foundation

/// FileOperationService 本身无状态，只调 FileManager.default（线程安全），可以放到后台队列用。
extension FileOperationService: @unchecked Sendable {}

/// 当前正在进行的文件移动（同一时间只允许一个），供分区里显示进度条与“取消”。
@MainActor
final class TransferCenter: ObservableObject {
    struct Active: Equatable {
        let id: UUID
        let zoneID: UUID?
        var title: String
        var fraction: Double
    }

    @Published private(set) var active: Active?
    private var token: TransferProgress?

    var isBusy: Bool { active != nil }

    func begin(zoneID: UUID?, title: String) -> (UUID, TransferProgress) {
        let id = UUID()
        // 进度回调来自后台复制线程：合并到主线程，变化超过 1% 才刷新界面
        let lastShown = Locked(-1.0)
        let progress = TransferProgress { [weak self] done, total in
            let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
            guard lastShown.update({ abs(fraction - $0) >= 0.01 || fraction >= 1 ? fraction : nil }) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.active?.id == id else { return }
                    self.active?.fraction = fraction
                }
            }
        }
        token = progress
        active = Active(id: id, zoneID: zoneID, title: title, fraction: 0)
        return (id, progress)
    }

    func finish(_ id: UUID) {
        guard active?.id == id else { return }
        active = nil
        token = nil
    }

    /// 用户点“取消”：正在跨盘复制的那一项立即停止并清掉未完成的临时副本，源文件完好；后面的项不再开始。
    func cancel() {
        token?.cancel()
        if active != nil { active?.title = "正在取消…" }
    }
}

/// 极简的加锁小盒子（给后台回调用）。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }

    /// transform 返回新值则写入并返回 true；返回 nil 表示不变。
    func update(_ transform: (Value) -> Value?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let new = transform(value) else { return false }
        value = new
        return true
    }
}
