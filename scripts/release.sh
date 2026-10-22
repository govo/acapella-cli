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

# 版本号只有一个真值（本仓库的 VERSION / --version），但二进制里的版本是编译进
# `CLIRunner.version` 的常量 —— 只改文件不改常量，产物会自报旧版本，而
# `brew test`（assert_match version.to_s）正好拿它比对，装完就红。
# 所以出包前把常量改写成本次版本，出包后再断言一遍二进制自报的版本。
CLI_VERSION_SWIFT="$CLI_PKG/Sources/acapella/CLIRunner.swift"
sync_cli_version_constant() {
  [ -f "$CLI_VERSION_SWIFT" ] || return 0
  /usr/bin/sed -i '' -E "s/(static let version = \")[^\"]*(\")/\1${VERSION}\2/" "$CLI_VERSION_SWIFT"
  if ! grep -q "static let version = \"${VERSION}\"" "$CLI_VERSION_SWIFT"; then
    echo "release.sh: could not set CLIRunner.version to $VERSION in $CLI_VERSION_SWIFT" >&2
    exit 4
  fi
  echo "==> CLIRunner.version = $VERSION"
}

if [ "$BUILD" -eq 1 ]; then
  if [ ! -d "$CLI_PKG" ]; then
    echo "release.sh: CLI package not found at $CLI_PKG (set ACAPELLA_CLI_PACKAGE)" >&2
    exit 3
  fi
  sync_cli_version_constant
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

# 断言：二进制自己说的版本 = 这次要发的版本。`--no-build` 复用旧产物时这一条同样有效
# （复用上一版二进制再打成本版的包，是这里最容易悄悄发生的事）。
# x86_64 那半要靠 Rosetta 才跑得起来；跑不动就跳过 —— 两个架构编的是同一份源码常量，
# arm64 对上了就已经说明常量被改对了。
for bin in "$ARM_BIN" "$X64_BIN"; do
  reported="$("$bin" --version 2>/dev/null | awk '{print $2}')"
  if [ -z "$reported" ]; then
    echo "==> note: $(dirname "$bin") binary did not run here; version assert skipped"
    continue
  fi
  if [ "$reported" != "$VERSION" ]; then
    echo "release.sh: $bin reports '$reported' but this release is $VERSION" >&2
    echo "            (bump CLIRunner.version, or rebuild without --no-build)" >&2
    exit 4
  fi
  echo "==> $(dirname "$bin") reports $VERSION"
done

echo "==> packaging $VERSION"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/arm64" "$STAGE/x64"
cp "$ARM_BIN" "$STAGE/arm64/acapella"
cp "$X64_BIN" "$STAGE/x64/acapella"

# 可复现打包：把 mtime 归一化 + gzip -n（不写文件名/时间戳）。
# 同样输入每次打出同样的字节，checksums 与 formula 才不会因为重跑而"无故变化"。
#
# 注意：**不要依赖 `tar --mtime`**。它在部分 tar（沙箱、旧 bsdtar）上不生效也不报错，
# 于是打包静默退回带时间戳的路径 —— 结果是"重新打包 → 哈希变了 → 指纹与已上传的
# release 资产不一致 → brew install 报 sha256 mismatch"。用 `touch -t` 改文件时间
# 再普通打包，所有 tar 都支持，没有静默失效的分支。
NORMALIZED_MTIME=202001010000
pack() {
  local dir="$1" out="$2"
  (
    set -o pipefail
    cd "$dir" || exit 1
    touch -t "$NORMALIZED_MTIME" acapella
    tar -cf - acapella | gzip -9n
  ) > "$out" || { echo "release.sh: failed to package $dir" >&2; rm -f "$out"; exit 1; }
  [ -s "$out" ] || { echo "release.sh: $out is empty" >&2; exit 1; }
}
pack "$STAGE/arm64" "$DIST/acapella-$VERSION-darwin-arm64.tar.gz"
pack "$STAGE/x64"   "$DIST/acapella-$VERSION-darwin-x64.tar.gz"

cp "$STAGE/arm64/acapella" "$HERE/acapella"
chmod +x "$HERE/acapella"
printf '%s\n' "$VERSION" > "$HERE/VERSION"

# checksums 只登记**本版**的两个包。
#
# 以前这里是 `shasum *.tar.gz`，dist/ 里留着上一版的包时会把旧哈希一起写进来 ——
# 于是 `gh release create v$(cat VERSION) dist/*.tar.gz` 会把旧版本的 tarball
# 也传进新 release（体积翻倍、资产名与本版对不上），checksums.txt 里也会多出
# 两条指向"这次没上传的文件"的记录。
( cd "$DIST" && shasum -a 256 \
    "acapella-$VERSION-darwin-arm64.tar.gz" \
    "acapella-$VERSION-darwin-x64.tar.gz" > checksums.txt )

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
#  已知审计噪音（drumai 同样有）：brew audit 会说 on_arm/on_intel 里不能放 url/sha256。
#  但块内语句照常求值，fetch/install 都正常；个人 tap 不跑 audit，所以保持这个写法
#  —— 换成 universal binary 才能消掉，代价是体积翻倍，不值得。
#

class Acapella < Formula
  desc "Command-line client for the Acapella app on macOS"
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
echo "  gh release create v$VERSION \\"
echo "    dist/acapella-$VERSION-darwin-arm64.tar.gz \\"
echo "    dist/acapella-$VERSION-darwin-x64.tar.gz \\"
echo "    dist/checksums.txt --title v$VERSION"
echo "  (tap) git -C <homebrew-tap> commit Formula/acapella.rb"
