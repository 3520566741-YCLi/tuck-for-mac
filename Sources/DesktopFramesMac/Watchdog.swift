import Darwin
import Foundation

/// 启动 / 结束看门狗子进程（TuckWatchdog，见 Sources/TuckWatchdog）。
///
/// Tuck 持有一条管道的写端，看门狗从读端阻塞等待：
/// - 正常退出时写 "C"，看门狗直接结束；
/// - Tuck 崩溃 / 被 kill -9 时内核关闭管道，看门狗读到 EOF，按隐藏清单恢复桌面原图标。
/// 不是登录项、不开机自启，只随 Tuck 一起存在；每个 Tuck 进程只有一个看门狗。
@MainActor
final class Watchdog {
    private var writeFD: Int32 = -1
    private(set) var pid: pid_t = 0

    func start(listFile: URL, desktop: URL) {
        guard writeFD < 0,
              let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TuckWatchdog"),
              FileManager.default.isExecutableFile(atPath: exe.path) else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        let readFD = fds[0], write = fds[1]
        _ = fcntl(write, F_SETFD, FD_CLOEXEC) // 写端不让任何子进程继承

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, readFD, 0) // 读端 → 看门狗的标准输入
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        // 除了显式 dup2 的标准输入外，其它描述符一律不继承
        // 独立进程组：在终端里 Ctrl-C、会话挂断时不会和 Tuck 一起被带走
        posix_spawnattr_setpgroup(&attrs, 0)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))

        let argv: [String] = [exe.path, listFile.path, desktop.path]
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var child: pid_t = 0
        let rc = posix_spawn(&child, exe.path, &actions, &attrs, &cargs, nil)
        for p in cargs { free(p) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attrs)
        close(readFD)
        if rc == 0 {
            writeFD = write
            pid = child
        } else {
            close(write)
        }
    }

    /// 正常退出：告诉看门狗“干净退出”，然后关掉管道。
    func stopCleanly() {
        guard writeFD >= 0 else { return }
        var c = UInt8(ascii: "C")
        _ = Darwin.write(writeFD, &c, 1)
        close(writeFD)
        writeFD = -1
        if pid > 0 {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG) // 回收，避免僵尸进程
        }
    }
}
