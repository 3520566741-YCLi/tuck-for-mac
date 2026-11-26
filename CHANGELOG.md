# 更新记录 / Changelog

版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。所有旧版本都保留在 [Releases](../../releases)。
Versions follow [Semantic Versioning](https://semver.org/). Every old version stays in [Releases](../../releases).

## v2.4.0 · 2026-11-26

怎么存都进分区，截图你说了算。 / However you save it, it lands in the zone; screenshots are up to you.

- **新文件自动移进分区覆盖所有保存方式**：不再只认浏览器的「下载」标记，网页里「另存为」、别的软件保存到桌面或「下载」的新文件也会移进下载分区。只收新建且已写完的：还被软件打开着的先等它关、Office 的 ~$ 锁文件和各种下载临时文件不碰；从别处挪进来的老文件、从分区拖回桌面 / 撤销放回的文件不会再被收走。
  **Moving new files covers every way of saving**: no longer limited to files carrying the browser's download mark; Save As from a web page and saves from other apps into the Desktop or Downloads are moved too. Only newly created, fully written files: files still open in an app wait until closed, Office ~$ lock files and download temp files are left alone, and old files moved in or files you drag back / undo aren't taken again.
- **截图可选**：截图默认不收；菜单里勾「截图也收」，还能选截图放进哪个下载分区。原来的「只收从网上下载的文件」开关去掉。
  **Screenshots optional**: not collected by default; tick “Include Screenshots” and pick which download zone they go to. The old “Only files downloaded from the web” switch is gone.
- 外观面板跟着系统深浅色：白天不再是浅底配白字。
  The Appearance panel follows the system light / dark look: no more white text on a light panel in daytime.

## v2.3.0 · 2026-11-24

每个分区自己的玻璃，下载直接进分区。 / Glass per zone, downloads straight into a zone.

- **每个分区单独调质感**：分区标题栏的调色板里直接选这个分区的 质感（清透 / 磨砂 / 暗色）、折射（关闭 / 边缘拉伸 / 光栅）、边缘（细边 / 高光 / 厚边），点哪个只改这个分区。菜单栏的「玻璃质感」总设置去掉了：升级后每个分区保持原样，新分区默认 清透 + 边缘拉伸 + 细边；旧的「棱镜」边缘并入「高光」。
  **Glass per zone**: a zone's palette button picks that zone's Glass (Clear / Frosted / Dark), Refraction (Off / Edge / Fluted) and Edge (Thin rim / Highlight / Thick edge). The global Glass Style menu is gone: existing zones keep their look, new zones start as Clear + Edge + Thin rim; the old Prism edge is merged into Highlight.
- **下载分区**：新建分区 › **下载分区**，在「Tuck 分区」里建一个真实文件夹，里面的文件自动出现在分区里（下载中的临时文件不出现），访达侧栏也点得到。Tuck 永远不删这个文件夹。
  **Download zones**: New Zone › **Download Zone** creates a real folder inside “Tuck Zones”; its files show in the zone automatically (in-progress downloads don't) and it's reachable from the Finder sidebar. Tuck never deletes it.
- **新下载自动移进分区**（菜单，默认关）：任何浏览器（Safari / Chrome / Edge / Firefox / Arc 等）新下载完成的文件，在「下载」或桌面上，都会被**移进**选中的下载分区，原处不再保留；不用改浏览器设置。只对打开后新下载完成的文件；各家浏览器的临时文件（.download / .crdownload / .part / .opdownload 等，以及 Firefox 先放的空文件）都等下完再说；同盘原子移动、重名加编号、绝不覆盖；「撤销上次移动」可放回；第一次会说明并请求读「下载」文件夹。
  **Move new downloads into a zone** (menu, off by default): files finished by any browser (Safari / Chrome / Edge / Firefox / Arc…), in Downloads or on the Desktop, are **moved** into the chosen download zone, with nothing left behind and no browser settings to change. Only new downloads after turning it on; every browser's temp files (.download / .crdownload / .part / .opdownload, and Firefox's empty placeholder) are waited out; same-disk atomic moves, numbered names on clashes, never overwriting; Undo Last Move puts one back; explains and asks for Downloads access the first time.
- 外观面板开在调色板按钮旁边，并先把这个分区提到前面，不再被旁边的分区盖住。
  The Appearance panel opens beside the palette button and brings its zone to the front, so neighbouring zones no longer cover it.

## v2.2.0 · 2026-11-24

会折射的玻璃，像访达一样的右键。 / Glass that refracts, a Finder-style right click.

- **液态玻璃更真**：边缘拉伸按真实玻璃的折射来算（凸弧形倒角 + 一点红蓝色散），最外圈一道细亮边、往里一圈很淡的厚度阴影；边缘折射不再跟着分区透明度一起变淡，调得很透时也看得出是一块有厚度的玻璃，中间保持通透。光栅玻璃改成真正的柱面透镜折射，棱更细（10pt），去掉了像贴纸的平铺条纹。大分区算一次约 20 毫秒，静止时不占 CPU。
  **More realistic liquid glass**: edge stretch now follows real refraction (a rounded convex bevel with a touch of colour fringing), with a thin bright rim and a faint thickness shadow just inside it. The edge no longer fades with the zone's opacity, so even very clear zones read as a slab of glass while the middle stays see-through. Fluted glass is now true cylindrical-lens refraction with finer 10 pt ribs, without the flat painted stripes. About 20 ms per large zone, zero CPU at rest.
- **自动排序**：分区空白处右键或「更多」菜单 → **排序方式**：无（手动）/ 名称 / 种类 / 修改日期 / 添加日期 / 大小，可**倒序**。名称排序和访达一样：不分大小写、数字按大小（file2 在 file10 前面）、中文系统下汉字按拼音。每个分区各自记住；新放进来的项目自动出现在该在的位置；自动排序时不能手动拖动调整（和访达一样），选「无」回到原来的手动顺序。**整理方式**：只按某一项排一次，之后还能手动拖。只改显示顺序，**绝不改文件名、不移动任何文件**。
  **Auto sort**: right-click empty space in a zone, or use More → **Sort By**: None (manual) / Name / Kind / Date Modified / Date Added / Size, with **Reverse Order**. Name sorting matches Finder: case-insensitive, numbers in numeric order (file2 before file10). Each zone remembers its own; new items appear in the right place; while sorted, drag-reordering is off (as in Finder), and None brings back your manual order. **Clean Up By** sorts once and keeps manual dragging. Display order only: **files are never renamed or moved**.
- 稳定性：上千个文件按「种类」排序时不再在悬停时卡顿（类型说明只在分区内容变化时重查）。
  Stability: sorting thousands of files by Kind no longer stutters on hover (kind info is only re-read when the zone's contents change).
- **玻璃折射**：分区玻璃像真玻璃一样弯折背后的壁纸。菜单 玻璃 → 折射：关闭 / **边缘拉伸**（默认，像真玻璃的边）/ **光栅玻璃**（长虹竖棱）。只在分区停下、改大小、换壁纸、切空间时后台算一次，静止时零耗电，普通图片壁纸不需要任何权限。
  **Glass refraction**: zones bend the wallpaper behind them like real glass. Menu Glass → Refraction: Off / **Edge stretch** (default, like a real glass edge) / **Fluted glass** (vertical ribs). Computed once in the background when a zone stops moving, resizes, or the wallpaper or Space changes; zero power at rest, and still images need no permission.
- **动态壁纸也折射**（可选，默认关）：系统动态 / 航拍壁纸不把画面交给 App，打开后只截壁纸那一层（截不到任何窗口、桌面图标和文件），只在内存里用、不存盘，需要「录屏」权限；2 秒超时、失败 60 秒内不再试。
  **Refraction on dynamic wallpapers** (optional, off by default): macOS doesn't share dynamic / aerial wallpapers with apps, so when turned on Tuck captures only the wallpaper layer (never windows, desktop icons or files), in memory only, never saved. Needs Screen Recording; 2-second timeout and a 60-second back-off after a failure.
- **边缘光效**：原版细白边（默认）之外，新增 晶透 / 棱镜 / 厚玻璃 三种受光边缘；MacBook 上**光随屏幕角度**滑动（读屏幕开合角度传感器，不要任何权限，卡住会自愈，可在菜单关闭）。
  **Edge light**: besides the original thin rim (default), three new light-catching rims: Crystal / Prism / Slab. On a MacBook the **highlight follows the lid angle** (reads the hinge sensor, no permission needed, self-heals if it stalls, can be turned off).
- **访达同款右键菜单**：打开方式、显示简介（⌘I）、重新命名（改扩展名会先确认）、复制副本（⌘D）、制作替身、压缩、拷贝 / 粘贴、标签、新建文件夹、服务；移到废纸篓（⌘⌫）可 ⌘Z 撤销，绝不直接删除。
  **Finder-style context menu**: Open With, Get Info (⌘I), Rename (asks before changing an extension), Duplicate (⌘D), Make Alias, Compress, Copy / Paste, Tags, New Folder, Services; Move to Trash (⌘⌫) can be undone with ⌘Z and never deletes outright.
- **「Tuck 分区」入口文件夹**：被收进分区、在桌面上隐藏的文件，在别的软件的「打开 / 上传」窗口里也看不到；现在个人文件夹里多一个「Tuck 分区」，按分区列出指向原文件的替身，上传时点进去就能选到。原文件不动，只增删 Tuck 自己做的链接，菜单里可关。
  **“Tuck Zones” folder**: files tucked into a zone are hidden on the desktop, so other apps' Open / Upload dialogs couldn't see them either. Your Home folder now has a “Tuck Zones” folder listing links to the originals, zone by zone. Originals are never touched; Tuck only adds and removes its own links, and it can be turned off in the menu.
- **英文界面**：界面跟系统语言自动切换中文 / English。
  **English interface**: follows the system language (Chinese / English).
- 稳定性：截壁纸层的 2 秒超时现在真正生效（之前截图卡住时会一直等）；测试 / 截图用的独立实例不再改写真实的「Tuck 分区」。
  Stability: the 2-second wallpaper-capture timeout now really fires (a stuck capture used to wait forever); separate test / screenshot instances no longer touch the real “Tuck Zones” folder.

## v2.1.0 · 2026-11-08

第一次公开发布。 / First public release.

- 液态玻璃分区：A 清透 / B 磨砂 / C 暗色。 / Liquid Glass zones: A Clear / B Frosted / C Dark.
- 收起成玻璃胶囊；放进分区的桌面文件在桌面上自动隐藏。 / Collapse into a glass capsule; desktop files in a zone are hidden on the desktop.
- 三种分区：普通、应用、文件。 / Three zone types: regular, app, folder.
- 像访达一样操作；分区内拖动排序。 / Finder-style items; drag to reorder inside a zone.
- 崩溃看门狗恢复桌面图标；跨盘移动先复制再进废纸篓；整批撤销。 / Crash watchdog restores desktop icons; cross-volume moves copy then trash; batch undo.
- 只在菜单栏，⌃⌥D 偷看，开机自启默认关闭，不联网、零依赖。 / Menu bar only, ⌃⌥D peek, launch at login off by default, no network, zero dependencies.
