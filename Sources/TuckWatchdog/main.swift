// Tuck 看门狗：极小的独立进程，只用 Darwin 系统调用（不加载 Foundation / AppKit），常驻内存很小、平时不占 CPU。
//
// 用法（由 Tuck 启动，用户不需要手动运行）：
//   TuckWatchdog <隐藏清单文件> <桌面目录>
// 标准输入是一条管道，Tuck 持有写端：
//   - Tuck 正常退出前写入一个字节 "C" → 看门狗直接结束；
//   - Tuck 崩溃 / 被 kill -9 → 管道被系统关闭（读到 EOF）→ 看门狗按清单恢复桌面原图标后结束。
// 只恢复：桌面直属、并且带 Tuck 扩展属性标记（io.github.tuckformac.tuck.hidden）的项目，绝不碰别的文件。
import Darwin

let args = CommandLine.arguments
guard args.count == 3 else { exit(2) }
let listPath = args[1]
let desktop = args[2]
let mark = "io.github.tuckformac.tuck.hidden"

// 只靠管道决定何时结束：忽略终止 / 中断 / 挂断信号，保证 Tuck 出事时看门狗还在
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)

// 1) 阻塞等待：父进程写 "C"（干净退出）或管道关闭（异常退出）
var byte: UInt8 = 0
var n: Int
repeat { n = read(0, &byte, 1) } while n < 0 && errno == EINTR
if n == 1 && byte == UInt8(ascii: "C") { exit(0) }

// 2) 异常退出：读取清单（NUL 分隔的绝对路径）
let fd = open(listPath, O_RDONLY)
guard fd >= 0 else { exit(0) }
var data: [UInt8] = []
var buf = [UInt8](repeating: 0, count: 4096)
while true {
    let r = read(fd, &buf, buf.count)
    if r <= 0 { break }
    data.append(contentsOf: buf[0..<r])
    if data.count > 4_000_000 { break } // 防御：清单异常大时不再读
}
close(fd)

func parentDir(_ p: String) -> String {
    guard let i = p.lastIndex(of: "/") else { return "" }
    return i == p.startIndex ? "/" : String(p[p.startIndex..<i])
}

func realPath(_ p: String) -> String? {
    var out = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(p, &out) != nil else { return nil }
    let bytes = out.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

let desktopReal = realPath(desktop) ?? desktop

// 3) 逐项恢复：只认桌面直属 + 带 Tuck 标记；符号链接不跟随
for chunk in data.split(separator: 0) {
    let path = String(decoding: Array(chunk), as: UTF8.self)
    guard path.hasPrefix("/"), !path.contains("\u{FFFD}") else { continue } // 非法 UTF-8 的路径跳过
    guard let parentReal = realPath(parentDir(path)), parentReal == desktopReal else { continue }
    guard getxattr(path, mark, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { continue }
    var st = stat()
    guard lstat(path, &st) == 0 else { continue }
    if st.st_flags & UInt32(UF_HIDDEN) != 0 {
        _ = lchflags(path, st.st_flags & ~UInt32(UF_HIDDEN))
    }
    _ = removexattr(path, mark, XATTR_NOFOLLOW)
}
exit(0)
