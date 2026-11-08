# Setup guide for AI assistants

> This file is for **the user's AI coding assistant**. The user hands you the repository; follow these steps. 中文：[AI_SETUP.md](AI_SETUP.md)

## 0. Ask the user first

Ask in a sentence or two; don't decide for them:

1. Is the prebuilt `Tuck.app` from [Releases](../../releases/latest) fine, or do they want to build from source? (Most people want the former; no Xcode needed.)
2. Do they have an Apple developer certificate? If so, sign with it (reinstalls keep permissions); otherwise sign ad-hoc.
3. Launch at login? (Off by default.)

## 1. Requirements

- macOS 14 or later; Liquid Glass needs macOS 26. Apple silicon or Intel (the package script defaults to arm64; change `--arch arm64` to `x86_64` on Intel).
- Building from source needs **full Xcode 26** (not just the command line tools) and `sudo xcode-select -s /Applications/Xcode.app`. `swift-testing` and `actool` (icon compilation) depend on it.
- No third-party dependencies, API keys or network services.

## 2. Build and test

```sh
swift build --disable-sandbox --cache-path .spm-cache
swift test  --disable-sandbox --cache-path .spm-cache     # 70 unit tests, all should pass
```

## 3. Package and install

```sh
# With a developer certificate:
export SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"   # see: security find-identity -v -p codesigning
./scripts/package-app.sh --install
```

- Without `SIGN_IDENTITY` the app is signed ad-hoc; on first launch, right-click it in Applications → Open.
- `--install` quits the running copy, moves the old `/Applications/Tuck.app` to the Trash (via the system `trash` command, macOS 15+; on older systems drag the old copy to the Trash yourself) and installs the new one.
- Package only: drop `--install`; the result is `dist/Tuck.app`.

## 4. First use (tell the user)

- Tuck lives in the menu bar (grid icon) only, not the Dock.
- Menu bar → **New Zone** → regular zone; drag desktop files in. Their desktop icons are hidden; the files don't move.
- Menu bar → **Glass Style** → A Clear / B Frosted / C Dark.
- `⌃⌥D` to peek: zones float above everything.
- Tuck needs **no** Accessibility, Screen Recording or Full Disk Access permission. If a zone is linked to a protected folder such as Documents or Downloads, macOS asks once; allow it.

## 5. Where data lives

- Layout: `~/Library/Application Support/Tuck/layout.json` (atomic writes, corrupt files quarantined, 5 backups, restorable from the menu).
- Settings: `defaults read io.github.tuckformac.tuck`.
- Launch at login writes `~/Library/LaunchAgents/io.github.tuckformac.tuck.plist` and removes it when turned off.

## 6. Rules when changing the code

1. **Never hard-delete user files**; move them to the Trash.
2. **Regular and app zones never move originals**; only folder zones move files, and Cancel is the default on name conflicts.
3. Desktop hiding uses only the Finder hidden flag plus the `io.github.tuckformac.tuck.hidden` extended attribute; **only restore what Tuck hid**.
4. Idle CPU must be 0: wake on folder changes only, never poll.
5. No third-party dependencies, no networking.

## 7. Screenshots / demos (never capture the user's own files)

Two environment variables point Tuck at a separate data folder and "desktop", leaving the user's real layout untouched:

```sh
DESKTOPFRAMES_DATA_DIR=/tmp/tuck-demo/data DESKTOPFRAMES_DESKTOP_DIR=/tmp/tuck-demo/desktop \
  /Applications/Tuck.app/Contents/MacOS/Tuck
```

Capturing needs Screen & System Audio Recording permission for your terminal or app. Hide the real desktop icons first (`defaults write com.apple.finder CreateDesktop -bool false; killall Finder`) and set it back to `true` afterwards.

## 8. Acceptance checklist

- [ ] `swift test` passes
- [ ] The grid icon appears in the menu bar; Tuck is not in the Dock
- [ ] New zone → drag in a desktop file → it disappears from the desktop and appears in the zone; Finder shows the original still in place
- [ ] Drag it back / quit Tuck → the desktop icon returns
- [ ] Click the arrow by the title to collapse into a capsule, click again to expand
- [ ] All three glass styles work; text is legible in dark mode and doesn't touch edges
- [ ] Activity Monitor shows 0% CPU at idle
