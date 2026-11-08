# 参与贡献 / Contributing

谢谢你愿意帮 Tuck 变得更好！ / Thanks for helping make Tuck better!

## 先开 issue / Open an issue first

- **报 bug**：用 [Bug 模板](../../issues/new?template=bug_report.yml)，写清 macOS 版本、芯片、怎么复现。
  **Bugs:** use the [bug template](../../issues/new?template=bug_report.yml) with your macOS version, chip and steps to reproduce.
- **想加功能**：先用 [功能模板](../../issues/new?template=feature_request.yml) 聊一聊，再动手写。
  **Features:** start with the [feature template](../../issues/new?template=feature_request.yml) before writing code.
- **安全问题**：不要开公开 issue，请看 [SECURITY.md](SECURITY.md)。 / **Security:** see [SECURITY.md](SECURITY.md).

## 提 PR / Pull requests

1. 一个 PR 只做一件事。 / One change per PR.
2. 跑测试：`swift test --disable-sandbox --cache-path .spm-cache`（需要完整 Xcode 26）。
   Run the tests: `swift test --disable-sandbox --cache-path .spm-cache` (full Xcode 26 required).
3. 改了界面，附白天和夜里、三种玻璃质感的截图；检查文字不贴边、不截断，玻璃没有穿模。
   For UI changes, attach day/night screenshots in all three glass styles; check nothing touches an edge, gets clipped, or bleeds through.
4. **截图里不要带你自己的文件名或个人信息**，用演示文件（`DESKTOPFRAMES_DATA_DIR` / `DESKTOPFRAMES_DESKTOP_DIR` 可以换一套独立的数据和桌面目录）。
   **No personal file names in screenshots;** use demo files (`DESKTOPFRAMES_DATA_DIR` / `DESKTOPFRAMES_DESKTOP_DIR` point Tuck at a separate data and desktop folder).

## 几条规矩 / House rules

- 删除一律移到废纸篓，绝不直接删用户文件。 / Every removal goes to the Trash; never hard-delete user files.
- 虚拟 / 应用分区绝不移动原文件。 / Virtual and app zones never move originals.
- 不加第三方依赖、不联网。 / No third-party dependencies, no networking.
- 闲置时 CPU 必须是 0：只在文件夹变化时唤醒，不轮询。 / Idle CPU must stay at 0: wake on folder changes only, never poll.
