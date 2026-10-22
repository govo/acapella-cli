#!/usr/bin/env bash
#
# release.sh —— 出 `acapella` 的发布产物（本仓库 = 二进制分发仓库）。
#
# 做六件事，任何一步失败就停：
#   1. 构建 arm64 与 x86_64 两个 release 二进制（不用 universal：体积翻倍）
#   2. Developer ID 签名（hardened runtime）—— ad-hoc 签名的包公证一定不过
#   3. 逐架构提交 Apple 公证（notarytool，每次要等苹果返回）
#   4. 各自打成单文件 tar.gz（解包后当前目录就是 acapella，Homebrew 直接 bin.install）
#   5. 写 dist/checksums.txt，并把 arm64 裸二进制放到仓库根
#   6. 生成 Homebrew formula（--formula 给了就整份覆盖，否则打到 stdout）
#
# 用法
#   ./scripts/release.sh
#   ./scripts/release.sh --version 0.2.0
#   ./scripts/release.sh --formula ../homebrew-tap/Formula/acapella.rb
#   ./scripts/release.sh --no-build          # 复用已有产物（只重新签名/打包）
#   ./scripts/release.sh --skip-sign         # 只编译不签名（拿不到证书时自测用）
#   ./scripts/release.sh --notary-profile X  # 换公证凭据 profile
#
# 前置（签名/公证那两步）：
#   - 钥匙串里有 "Developer ID Application"（Apple Development / Apple Distribution 都不行）
#   - 公证凭据已存：xcrun notarytool store-credentials <profile>
#   证书与凭据只在这台机器上，不进 CI、不进仓库。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLI_PKG="${ACAPELLA_CLI_PACKAGE:-$HERE/../Acapella/Acapella/CLI}"

# 两个临时目录都在后面按需创建；统一在这里挂一个清理 trap。
# 分开挂会互相覆盖（后挂的那个把先挂的顶掉，公证用的 zip 就留在 /tmp 里了）。
STAGE=""
NOTARY_STAGE=""
trap 'rm -rf ${STAGE:+"$STAGE"} ${NOTARY_STAGE:+"$NOTARY_STAGE"}' EXIT
VERSION="$(tr -d '[:space:]' < "$HERE/VERSION" 2>/dev/null || echo 0.1.0)"
FORMULA=""
BUILD=1
SIGN=1
IDENTITY="${ACAPELLA_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${ACAPELLA_NOTARY_PROFILE:-}"
REPO="${ACAPELLA_REPO:-govo/acapella-cli}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --formula) FORMULA="${2:?}"; shift 2 ;;
    --repo) REPO="${2:?}"; shift 2 ;;
    --identity) IDENTITY="${2:?}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:?}"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --skip-sign) SIGN=0; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# ── 签名 + 公证 ────────────────────────────────────────────────────────────
# 为什么要做：brew 与 curl 下载不带 com.apple.quarantine，不签也能跑；但**别人用浏览器
# 或 AirDrop 拿到 tarball** 时会打上隔离属性，没签名/没公证就是 exec 直接被杀。
# 签了名 + 过了公证的包，Gatekeeper 直接放行，不用教用户 xattr。
#
# 两个坑（照 drumai 的 build-cli.sh 抄的，别自己改）：
#   1. linker 已经给产物做过 ad-hoc 签名，直接再签会叠两层 → 先 --remove-signature。
#   2. `-options runtime`（hardened runtime）是公证的硬要求；Apple Development /
#      Apple Distribution 证书都不能用于公证，只认 Developer ID Application。
if [ "$SIGN" -eq 1 ]; then
  if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)"/\1/p' | head -1)"
  fi
  if [ -z "$IDENTITY" ]; then
    echo "release.sh: 钥匙串里没有 Developer ID Application 证书" >&2
    echo "            （Apple Development / Apple Distribution 不能用于公证）" >&2
    echo "            Xcode → Settings → Accounts → Manage Certificates 里加一张，" >&2
    echo "            或者加 --skip-sign 只编译不签名（产物只能自己测）" >&2
    exit 5
  fi
  # 凭据 profile：优先显式/环境变量指定的，否则 acapella；两个都没有时退回 drumai
  # （同一个 Apple ID 团队 9RRNVTE2RE，凭据是账号级的，不是按 app 分的）。
  if [ -z "$NOTARY_PROFILE" ]; then
    if xcrun notarytool history --keychain-profile acapella >/dev/null 2>&1; then
      NOTARY_PROFILE=acapella
    elif xcrun notarytool history --keychain-profile drumai >/dev/null 2>&1; then
      NOTARY_PROFILE=drumai
      echo "==> note: 复用 drumai 的公证凭据（keychain profile: drumai）"
    else
      NOTARY_PROFILE=acapella
    fi
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "release.sh: 公证凭据 profile '$NOTARY_PROFILE' 不存在" >&2
    echo "            先跑：xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
    echo "            或者加 --skip-sign 只编译不签名" >&2
    exit 5
  fi

  echo "==> signing as: $IDENTITY"
  for bin in "$ARM_BIN" "$X64_BIN"; do
    /usr/bin/codesign --remove-signature "$bin" 2>/dev/null || true
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$bin" \
      || { echo "release.sh: codesign failed on $bin" >&2; exit 5; }
    /usr/bin/codesign --verify --strict "$bin" \
      || { echo "release.sh: codesign verify failed on $bin" >&2; exit 5; }
    echo "==> signed $(basename "$(dirname "$bin")")"
  done

  # notarytool 只吃 .zip/.pkg/.dmg，裸 Mach-O 先 ditto 成 zip（--keepParent 保住里面的文件名）。
  echo "==> notarizing (each submission waits for Apple)"
  NOTARY_STAGE="$(mktemp -d)"

  # 骨架名按架构写死，不要从 $bin 的目录名推 —— 两个架构的产物都叫 .../release/acapella，
  # 推出来的 tag 全是 "release"，zip 同名、日志也分不清是哪个架构。
  for entry in "arm64:$ARM_BIN" "x64:$X64_BIN"; do
    arch_tag="${entry%%:*}"
    bin="${entry#*:}"
    zip="$NOTARY_STAGE/acapella-$VERSION-darwin-$arch_tag.zip"
    /usr/bin/ditto -c -k --keepParent "$bin" "$zip"
    echo "    $arch_tag uploading…"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait \
      || { echo "release.sh: notarization failed for $arch_tag" >&2
           echo "            看日志：xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
           exit 6; }
    # staple 把票据钉进二进制（离线也能过）。裸 Mach-O 常常不支持，失败只警告 ——
    # 联网校验照样放行，只影响「完全离线 + 带 quarantine」的首次运行。
    if xcrun stapler staple "$bin" >/dev/null 2>&1; then
      echo "    $arch_tag stapled"
    else
      echo "    $arch_tag staple skipped (裸可执行文件常见；联网校验不受影响)"
    fi
  done
else
  echo "==> WARNING: 跳过签名与公证（--skip-sign）——这份产物只能自己测，不能发布" >&2
fi

echo "==> packaging $VERSION"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/arm64" "$STAGE/x64"
cp "$ARM_BIN" "$STAGE/arm64/acapella"
cp "$X64_BIN" "$STAGE/x64/acapella"

# 可复现打包：把 mtime 归一化 + gzip -n（不写文件名/时间戳），
# 让**打包这一步**不引入随机性。
#
# 注意：**不要依赖 `tar --mtime`**。它在部分 tar（沙箱、旧 bsdtar）上不生效也不报错，
# 于是打包静默退回带时间戳的路径 —— 结果是"重新打包 → 哈希变了 → 指纹与已上传的
# release 资产不一致 → brew install 报 sha256 mismatch"。用 `touch -t` 改文件时间
# 再普通打包，所有 tar 都支持，没有静默失效的分支。
#
# 另：**签名带 Apple 时间戳（--timestamp），所以二进制本身逐次构建不同** ——
# 重新构建的包哈希必然变，只有「同一份二进制重新打包」才字节相同。别拿"重跑应得同一 sha"
# 去做断言；要稳定就复用已有产物 + `--no-build`。
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
