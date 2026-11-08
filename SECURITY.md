# 安全 / Security

## 设计 / Design

- **不联网**：Tuck 不发任何网络请求，没有遥测、账号或更新检查。
  **No network:** Tuck makes no network requests; no telemetry, accounts or update checks.
- **绝不直接删除**：替换掉的旧文件进废纸篓；跨盘移动先复制、校验，再把原件移到废纸篓。Tuck 不会清空废纸篓。
  **Never deletes:** replaced files go to the Trash; cross-volume moves copy and verify first, then move the original to the Trash. Tuck never empties the Trash.
- **虚拟 / 应用分区不动原文件**；只有文件分区会移动文件，同名冲突默认「取消」。
  **Virtual and app zones never move originals;** only folder zones move files, and Cancel is the default on name conflicts.
- **桌面隐藏只用访达隐藏标记**（同 `chflags hidden`），并用扩展属性标记「是 Tuck 隐藏的」；只恢复自己隐藏的、桌面直属的项目，用户原本隐藏的文件绝不碰。崩溃时由约 2MB 的看门狗进程恢复。
  **Desktop hiding uses only the Finder hidden flag** (like `chflags hidden`) plus an extended attribute marking what Tuck hid; it only restores items it hid directly on the Desktop. A ~2 MB watchdog restores them after a crash.
- **只打开本地文件 URL**；全局快捷键用 Carbon 热键注册，不需要辅助功能权限，也不监听其它按键。
  **Opens local file URLs only;** the global shortcut is a Carbon hotkey that needs no Accessibility permission and listens to no other keys.
- **开机自启默认关闭**，打开后只写一个用户级 LaunchAgent，关掉时只删自己写的那一个。
  **Launch at login is off by default;** turning it on writes one user LaunchAgent, and turning it off removes only that one.
- 布局文件原子写入，损坏时隔离保留，最近 5 份备份可恢复。
  The layout file is written atomically, quarantined if corrupt, with the last 5 backups restorable.

## 报告漏洞 / Reporting a vulnerability

请用 GitHub 的 [私下报告漏洞](../../security/advisories/new) 功能，不要开公开 issue。
Please use GitHub's [private vulnerability reporting](../../security/advisories/new) instead of a public issue.
