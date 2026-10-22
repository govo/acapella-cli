# acapella-cli

`acapella` 是驱动 **Acapella.app**（macOS）的命令行客户端。App 是唯一写入者，CLI 只发命令、
收 JSON —— 所以它能被脚本和 AI 安全使用，不会把工程写坏。

```
acapella doctor     # App 在不在、token 对不对
acapella state      # 当前工程的完整快照（唯一事实）
acapella caps       # 所有命令 + 参数（机器可读）
```

## 安装

### Homebrew（推荐）

```bash
brew install govo/tap/acapella
acapella --version
```

### 直接下载

从 [Releases](https://github.com/govo/acapella-cli/releases) 取对应架构的 tar.gz：

```bash
tar -xzf acapella-0.1.0-darwin-arm64.tar.gz     # Intel 用 -x64
sudo mv acapella /usr/local/bin/
xattr -d com.apple.quarantine /usr/local/bin/acapella 2>/dev/null || true
```

### 本地构建（开发机）

发布产物不进 git，所以 clone 下来没有二进制。自己出一个：

```bash
./scripts/release.sh --version 0.1.0     # 生成 ./acapella（arm64，约 600K）
./acapella --version
```

## 前置条件

1. macOS 14+，Acapella.app 正在运行。
2. App → 设置 → **「AI 控制」** → 打开开关（默认关闭）。
3. 打开后 App 会写 token 到容器内 `Application Support/AgentControl/token`，
   CLI 与 App 读同一个文件；关掉开关会轮换 token。

CLI 不会自己启动 App，也不会改你的配置。连不上时先 `acapella doctor`。

## 仓库里有什么

```
scripts/release.sh                # 构建 + 打包 + 写校验和 + 生成 formula
VERSION                           # 最近一次发版的版本号
README.md
.gitignore
```

`release.sh` 的产物**不进 git**（见 `.gitignore`），它们属于一次发布而不是一段源码：

```
acapella                          # 裸二进制（arm64），方便直接拷
dist/
  acapella-0.1.0-darwin-arm64.tar.gz
  acapella-0.1.0-darwin-x64.tar.gz
  checksums.txt                   # 上面两个包一起校验
```

理由很实际：每次发版都往 git 里塞 ~1MB 二进制，一百个版本就是 100MB 的永久历史，
而 GitHub Releases 本来就是干这个的 —— formula 的 `url` 也直接指那里。

tar.gz **解开就是单个 `acapella` 文件**（没有目录层），Homebrew 才能 `bin.install "acapella"`。

为什么不发 universal binary：胖二进制体积翻倍，两个薄包更省，也是 Homebrew 的常规做法。

## 校验

```bash
cd dist && shasum -a 256 -c checksums.txt
```

## 发版流程

```bash
# 1. 改版本号（Acapella/Acapella/CLI/Sources/acapella/CLIRunner.swift 的 `version`）
# 2. 出产物并同步 formula
./scripts/release.sh --version 0.1.0 \
    --formula ../homebrew-tap/Formula/acapella.rb

# 3. 传到 GitHub Release（tag = v<版本>）
git tag v0.1.0 && git push origin v0.1.0
gh release create v0.1.0 dist/*.tar.gz --title v0.1.0

# 4. 提交 tap
git -C ../homebrew-tap add Formula/acapella.rb
git -C ../homebrew-tap commit -m "acapella 0.1.0"
git -C ../homebrew-tap push
```

`release.sh` 生成整份 formula（与 `drumai.rb` 的风格一致），**不要手工改 url/sha256**：
下次发版会整份覆盖。

## 退出码（写脚本时看这个）

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | CLI/IO 失败，或 App 内部错误 |
| 2 | 用法错 / `BAD_REQUEST` |
| 3 | 连不上 App（没监听 / token 不对） |
| 4 | `CONFLICT`（`--if-revision` 过期） |
| 5 | `FORBIDDEN`（权限档位不够） |
| 6 | `NOT_FOUND`（工程/轨 token 过期） |
| 7 | `PRECONDITION_FAILED`（缺节拍网格、循环未设…） |
| 8 | `UNSUPPORTED`（此版本没做） |
| 9 | `BUSY`（录音/导出/分析中） |
| 10 | `LIMIT_REACHED` |

## 本版本没做的（别在文档里承诺）

- `project import` / `midi import` / `take import`：需要 App 侧上传端点，当前返回 `UNSUPPORTED`。
- `harmony …` / `fx …` / `chords …` / `key analyze`：没有这些命令；编和声用 `track add --kind midi`
  + `notes replace`。
- 网格 MV 导出、SSE watch、批量事务：P1。

AI 使用手册在 [`govo/acapella-skill`](https://github.com/govo/acapella-skill)（skill 名
`acapella-arranger`）。
