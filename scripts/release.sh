#!/usr/bin/env bash
#
# release.sh —— 出 `acapella` 的发布产物（本仓库 = 二进制分发仓库）。
#
# 做四件事，任何一步失败就停：
#   1. 构建 arm64 与 x86_64 两个 release 二进制（不用 universal：体积翻倍）
#   2. 各自打成单文件 tar.gz（解包后当前目录就是 acapella，Homebrew 直接 bin.install）
#   3. 写 dist/checksums.txt，并把 arm64 裸二进制放到仓库根
#   4. 生成 Homebrew formula（--formula 给了就整份覆盖，否则打到 stdout）
#
# 用法
#   ./scripts/release.sh
#   ./scripts/release.sh --version 0.2.0
#   ./scripts/release.sh --formula ../homebrew-tap/Formula/acapella.rb
#   ./scripts/release.sh --no-build          # 复用已有产物（只重新打包）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLI_PKG="${ACAPELLA_CLI_PACKAGE:-$HERE/../Acapella/Acapella/CLI}"
VERSION="$(tr -d '[:space:]' < "$HERE/VERSION" 2>/dev/null || echo 0.1.0)"
FORMULA=""
BUILD=1
REPO="${ACAPELLA_REPO:-govo/acapella-cli}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --formula) FORMULA="${2:?}"; shift 2 ;;
    --repo) REPO="${2:?}"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "release.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

DIST="$HERE/dist"
mkdir -p "$DIST"

if [ "$BUILD" -eq 1 ]; then
  if [ ! -d "$CLI_PKG" ]; then
    echo "release.sh: CLI package not found at $CLI_PKG (set ACAPELLA_CLI_PACKAGE)" >&2
    exit 3
  fi
  echo "==> building arm64"
  ( cd "$CLI_PKG" && swift build -c release --disable-sandbox --scratch-path /tmp/acapella-release-arm64 )
  echo "==> building x86_64"
  ( cd "$CLI_PKG" && swift build -c release --arch x86_64 --disable-sandbox --scratch-path /tmp/acapella-release-x64 )
  ARM_BIN=/tmp/acapella-release-arm64/release/acapella
  X64_BIN=/tmp/acapella-release-x64/release/acapella
else
  ARM_BIN="${ARM_BIN:-/tmp/acapella-release-arm64/release/acapella}"
  X64_BIN="${X64_BIN:-/tmp/acapella-release-x64/release/acapella}"
fi

for bin in "$ARM_BIN" "$X64_BIN"; do
  [ -x "$bin" ] || { echo "release.sh: missing $bin" >&2; exit 3; }
done

echo "==> packaging $VERSION"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/arm64" "$STAGE/x64"
cp "$ARM_BIN" "$STAGE/arm64/acapella"
cp "$X64_BIN" "$STAGE/x64/acapella"

# 可复现打包：mtime 固定 + gzip -n（不写文件名/时间戳）。
# 同样的二进制每次打出同样的哈希，checksums 与 formula 才不会因为重跑而"无故变化"。
# 但 `tar --mtime` 不是所有 tar 都有（沙箱/旧 bsdtar 不支持）→ 先探测，不支持就退回普通 tar。
REPRO=0
if ( cd "$STAGE/arm64" && tar --mtime='UTC 2020-01-01' -cf /dev/null acapella ) 2>/dev/null; then
  REPRO=1
else
  echo "note: this tar has no --mtime; packages will not be byte-reproducible" >&2
fi

pack() {
  local dir="$1" out="$2"
  (
    set -o pipefail
    cd "$dir" || exit 1
    if [ "$REPRO" = "1" ]; then
      tar --mtime='UTC 2020-01-01' -cf - acapella | gzip -9n
    else
      tar -cf - acapella | gzip -9n
    fi > "$out"
  ) || { echo "release.sh: failed to package $dir" >&2; rm -f "$out"; exit 1; }
  [ -s "$out" ] || { echo "release.sh: $out is empty" >&2; exit 1; }
}
pack "$STAGE/arm64" "$DIST/acapella-$VERSION-darwin-arm64.tar.gz"
pack "$STAGE/x64"   "$DIST/acapella-$VERSION-darwin-x64.tar.gz"

cp "$STAGE/arm64/acapella" "$HERE/acapella"
chmod +x "$HERE/acapella"
printf '%s\n' "$VERSION" > "$HERE/VERSION"

( cd "$DIST" && shasum -a 256 *.tar.gz > checksums.txt )

ARM_SHA="$(awk '/arm64/{print $1}' "$DIST/checksums.txt")"
X64_SHA="$(awk '/x64/{print $1}' "$DIST/checksums.txt")"

echo "==> $DIST/checksums.txt"
cat "$DIST/checksums.txt"

FORMULA_TEXT="$(cat <<RUBY
#
#  acapella.rb —— Homebrew formula。由 acapella-cli/scripts/release.sh 生成，
#  发新版本时整份覆盖本文件，不要手工改 url 与 sha256。
#
#  与 drumai 一致：一个 formula 覆盖两个架构，brew 按本机 CPU 选块；
#  二进制挂在 $REPO 的 Release 上，tag 就是 v<版本>。
#

class Acapella < Formula
  desc "Command line client for the Acapella app on macOS"
  homepage "https://github.com/$REPO"
  version "$VERSION"

  on_arm do
    url "https://github.com/$REPO/releases/download/v$VERSION/acapella-$VERSION-darwin-arm64.tar.gz"
    sha256 "$ARM_SHA"
  end

  on_intel do
    url "https://github.com/$REPO/releases/download/v$VERSION/acapella-$VERSION-darwin-x64.tar.gz"
    sha256 "$X64_SHA"
  end

  def install
    bin.install "acapella"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/acapella --version")
  end
end
RUBY
)"

if [ -n "$FORMULA" ]; then
  mkdir -p "$(dirname "$FORMULA")"
  printf '%s\n' "$FORMULA_TEXT" > "$FORMULA"
  echo "==> wrote $FORMULA"
else
  printf '%s\n' "$FORMULA_TEXT"
fi

echo
echo "next:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION dist/*.tar.gz --title v$VERSION"
echo "  (tap) git -C <homebrew-tap> commit Formula/acapella.rb"
