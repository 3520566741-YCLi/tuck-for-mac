import Darwin
import Foundation

/// 监听一组文件夹的“直接内容”变化（新增 / 删除 / 改名），只看这一层、不递归子目录。
///
/// 每个文件夹一个内核 vnode 事件源（O_EVTONLY 打开，不阻止卸载卷）：只有该文件夹本身
/// 的目录项变化才会唤醒，平时零唤醒、零 CPU。变化合并 1 秒后回调一次。
/// 替代旧版每 1.5 秒轮询；也避免 FSEvents 递归监听时，条目放在 ~/Documents 之类的位置
/// 会被整个子树（缓存、偏好写入）频繁唤醒。
///
/// 只在主线程使用；回调也在主线程。
@MainActor
final class FolderWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private let onChange: @MainActor () -> Void

    /// 同时监听的文件夹上限（每个占一个文件描述符），超出部分不监听（启动和菜单仍可手动清理）。
    static let maxFolders = 128

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// 更新监听集合：只增删有变化的部分。
    func watch(paths newPaths: Set<String>) {
        let wanted = Set(newPaths.sorted().prefix(Self.maxFolders))
        for path in sources.keys where !wanted.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in wanted where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 文件夹本身被删除 / 改名：旧描述符已失效，丢掉它，下次刷新集合时重新打开。
                    if let source, !source.data.isDisjoint(with: [.delete, .rename]) {
                        self.sources.removeValue(forKey: path)?.cancel()
                    }
                    self.scheduleCallback()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

    /// 1 秒内的多次变化合并成一次回调。
    private func scheduleCallback() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
