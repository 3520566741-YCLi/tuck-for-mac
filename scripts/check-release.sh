#!/bin/zsh
# 发版前检查打包好的 Tuck.app 里有没有个人信息（编译路径、邮箱、证书名）。
#   ./scripts/check-release.sh [dist/Tuck.app]
#   ./scripts/check-release.sh --self-test <没 strip 过的旧二进制>   # 自测：必须报错
# 公开发布时必须 0 命中；私人版用开发证书签名，签名里的证书邮箱会命中，属预期。
# 注意：不用 strings（macOS 自带的 strings 对这类二进制读不全，会漏报），直接 grep 原始字节。
set -uo pipefail
PATTERN='/Users/[[:alnum:]_.-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(com|cn|net|org)|Apple Development|Harness'

scan_file() {
  LC_ALL=C /usr/bin/grep -a -o -E "$PATTERN" "$1" 2>/dev/null | sort | uniq -c | head -20
}

if [[ "${1:-}" == "--self-test" ]]; then
  out="$(scan_file "$2")"
  if [[ -n "$out" ]]; then echo "✅ 自测通过：旧二进制能被查出来"; echo "$out"; exit 0
  else echo "❌ 自测失败：扫描没查出旧二进制里的路径"; exit 1; fi
fi

APP="${1:-dist/Tuck.app}"
hits=0
while IFS= read -r -d '' f; do
  out="$(scan_file "$f")"
  if [[ -n "$out" ]]; then
    echo "⚠️  ${f#$APP/}:"; echo "$out"; hits=1
  fi
done < <(find "$APP" -type f -print0)
sig="$(codesign -dvv "$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=|Signature=' || true)"
[[ -n "$sig" ]] && { echo "ℹ️  签名信息："; echo "$sig"; }
if (( hits == 0 )); then echo "✅ 整个 .app 里没有个人路径、邮箱或证书名"
else echo "❌ 有命中，不能公开发布（私人版的证书邮箱命中属预期）"; exit 1; fi
