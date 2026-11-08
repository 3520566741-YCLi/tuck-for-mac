# 给 AI 的安装说明

> 这份是写给**用户的 AI 编程助手**看的。用户把仓库交给你，你照着做。English: [AI_SETUP.en.md](AI_SETUP.en.md)

## 0. 先问用户

开工前用一两句话问清楚，别替用户做决定：

1. 直接用 [Releases](../../releases/latest) 里打包好的 `Tuck.app` 就行，还是要从源码构建？（大多数人选前者，不需要 Xcode。）
2. 有没有 Apple 开发者证书？有的话签名用它（以后重装不用重新授权）；没有就 ad-hoc 签名。
3. 要不要登录时自动启动？（默认关。）

## 1. 环境要求

- macOS 14 及以上；液态玻璃效果需要 macOS 26。Apple 芯片或 Intel 都可以（打包脚本默认 arm64，Intel 机器把 `--arch arm64` 改成 `x86_64`）。
- 从源码构建需要**完整的 Xcode 26**（不是只有命令行工具），并 `sudo xcode-select -s /Applications/Xcode.app`。`swift-testing` 和 `actool`（编译图标）都依赖完整 Xcode。
- 不需要任何第三方依赖、API key 或网络服务。

## 2. 构建和测试

```sh
swift build --disable-sandbox --cache-path .spm-cache
swift test  --disable-sandbox --cache-path .spm-cache     # 70 个单元测试，应全部通过
```

## 3. 打包安装

```sh
# 有开发者证书：
export SIGN_IDENTITY="Apple Development: 你的证书名 (TEAMID)"   # security find-identity -v -p codesigning 可查
./scripts/package-app.sh --install
```

- 不设 `SIGN_IDENTITY` 就用 ad-hoc 签名；第一次打开要在「应用程序」里右键 → 打开。
- `--install` 会先退出正在运行的旧版，把旧的 `/Applications/Tuck.app` 移到废纸篓（用系统 `trash` 命令，macOS 15+；更老的系统请手动把旧版拖进废纸篓），再装新版。
- 只打包不安装：去掉 `--install`，产物在 `dist/Tuck.app`。

## 4. 首次使用（告诉用户）

- Tuck 只在菜单栏（四宫格图标），不进 Dock。
- 菜单栏 → **新建分区** → 普通分区；把桌面文件拖进去。桌面上的原图标会被隐藏，文件不动。
- 菜单栏 → **玻璃质感** → A 清透 / B 磨砂 / C 暗色。
- `⌃⌥D` 偷看：分区临时浮到最上层。
- Tuck **不需要**辅助功能、屏幕录制、完全磁盘访问等权限。如果用户把分区关联到「文稿」「下载」之类受保护的文件夹，系统会弹一次访问授权，点允许即可。

## 5. 数据在哪

- 布局：`~/Library/Application Support/Tuck/layout.json`（原子写入、损坏自动隔离、保留 5 份备份，菜单栏「恢复备份」可找回）。
- 设置：`defaults read io.github.tuckformac.tuck`。
- 开机自启：打开后写 `~/Library/LaunchAgents/io.github.tuckformac.tuck.plist`，关掉时删掉。

## 6. 规矩（改代码时必须守）

1. **绝不直接删除用户文件**，只移到废纸篓。
2. **普通 / 应用分区绝不移动原文件**；只有文件分区真实移动，同名冲突默认「取消」。
3. 桌面隐藏只用访达隐藏标记 + `io.github.tuckformac.tuck.hidden` 扩展属性；**只恢复 Tuck 自己隐藏的**。
4. 闲置 CPU 必须为 0：只在文件夹变化时唤醒，不轮询。
5. 不加第三方依赖、不联网。

## 7. 截图 / 演示（不要拍到用户自己的文件）

用两个环境变量让 Tuck 用一套独立的数据和「桌面」，完全不碰用户真实布局：

```sh
DESKTOPFRAMES_DATA_DIR=/tmp/tuck-demo/data DESKTOPFRAMES_DESKTOP_DIR=/tmp/tuck-demo/desktop \
  /Applications/Tuck.app/Contents/MacOS/Tuck
```

截图需要给你所在的终端或应用开「屏幕与系统音频录制」权限。截图前先隐藏真实桌面图标（`defaults write com.apple.finder CreateDesktop -bool false; killall Finder`），拍完改回 `true`。

## 8. 验收清单

- [ ] `swift test` 全过
- [ ] 菜单栏出现四宫格图标，Dock 里没有 Tuck
- [ ] 新建分区 → 拖进一个桌面文件 → 桌面上它消失、分区里出现；访达里确认原文件还在原位
- [ ] 从分区拖回桌面 / 退出 Tuck → 桌面图标恢复
- [ ] 点标题左侧箭头收成胶囊，再点展开
- [ ] 三种玻璃质感切换生效；深色模式下文字清楚、不贴边
- [ ] 活动监视器里闲置 CPU 为 0%
