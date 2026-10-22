#!/usr/bin/env bash
#
# smoke.sh —— 对着**正在运行的** Acapella.app 做一次端到端冒烟。
#
# 为什么需要它：CLI 与 App 之间的 52 条命令，语法错、参数错、时序错都不会在编译期暴露。
# 这个脚本把"读 → 建工程 → 写音符 → 渲染 → 走带 → 循环 → 导出 → 质检 → 清理"
# 串成一条链，任何一环返回非 0 或缺少关键字段就报 FAIL，并打印原始 JSON。
#
# 用法
#   ./scripts/smoke.sh                 # 完整冒烟，结束后删掉自己建的测试工程
#   ./scripts/smoke.sh --keep          # 保留测试工程，便于进 App 里看结果
#   ./scripts/smoke.sh --errors        # 额外验证错误路径（错 token / ifRevision）
#   ./scripts/smoke.sh --verbose       # 每一步都打印收到的 JSON
#
# 前置：App 已启动且「设置 → AI 控制」已打开（或带 --agent-serve 启动）。
#       `acapella doctor` 能过，这个脚本才有意义 —— 它第一步就会跑 doctor。
#
# 退出码：0 全过 / 1 有失败项 / 3 连不上 App（doctor 没过）
#
set -uo pipefail

BIN="${ACAPELLA:-acapella}"
KEEP=0
ERRORS=0
VERBOSE=0
STEP_TOTAL=0
STEP_FAILED=0
FAILED_NAMES=()
NEW_PROJECT=""
NEW_TRACK=""
LAST_OUT=""
LAST_ERR=""
LAST_CODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --errors) ERRORS=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "smoke.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "smoke.sh: jq is required (brew install jq)" >&2; exit 2; }

pass() { STEP_TOTAL=$((STEP_TOTAL+1)); printf '  ✓ %s\n' "$1"; }
fail() {
  STEP_TOTAL=$((STEP_TOTAL+1)); STEP_FAILED=$((STEP_FAILED+1)); FAILED_NAMES+=("$1")
  printf '  ✗ %s\n' "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$2"
  [ -n "$LAST_OUT" ] && printf '      got: %s\n' "$(printf '%s' "$LAST_OUT" | head -c 300 | tr '\n' ' ')"
  [ -n "$LAST_ERR" ] && printf '      err: %s\n' "$(printf '%s' "$LAST_ERR" | head -c 300 | tr '\n' ' ')"
}

# rpc <args...> —— 跑一条命令，输出留在 LAST_OUT / LAST_ERR / LAST_CODE
rpc() {
  LAST_OUT="$("$BIN" "$@" --envelope 2>/tmp/smoke-err.txt)"
  LAST_CODE=$?
  LAST_ERR="$(cat /tmp/smoke-err.txt 2>/dev/null)"
  [ "$VERBOSE" -eq 1 ] && printf '      $ acapella %s → %s\n' "$*" "$(printf '%s' "$LAST_OUT" | head -c 400)"
  return 0
}

# 断言 ok=true 且 code=0
ok_true() {
  [ "$LAST_CODE" -eq 0 ] && [ "$(printf '%s' "$LAST_OUT" | jq -r '.ok // false' 2>/dev/null)" = "true" ]
}

json() { printf '%s' "$LAST_OUT" | jq -r "$1" 2>/dev/null; }

# ---------------------------------------------------------------- 0. 连得上吗
echo "acapella smoke — $("$BIN" --version 2>/dev/null | head -1)"
echo
echo "0. 连通性"

rpc doctor
if [ "$LAST_CODE" -eq 3 ]; then
  echo "  ✗ 连不上 App（doctor 退出码 3）"
  printf '%s\n' "$LAST_OUT" | sed 's/^/    /' | head -12
  echo
  echo "  先解决这一步：App 在运行 → 设置 → 「AI 控制」打开"
  echo "  （或 open -a Acapella --args --agent-serve）"
  exit 3
fi
ok_true && pass "doctor" || fail "doctor" "退出码 $LAST_CODE"

# ---------------------------------------------------------------- 1. 只读
echo
echo "1. 只读命令（协议 / 快照 / 自描述）"

rpc state
if ok_true && [ "$(json '.data.project' | head -c 1)" = "{" ]; then
  pass "state — 工程「$(json '.data.project.name')」，$(json '.data.tracks | length') 条轨"
else
  fail "state" "缺少 data.project"
fi

rpc caps
CMDS="$(json '.data.commands | length')"
if ok_true && [ "${CMDS:-0}" -ge 40 ]; then
  pass "caps — $CMDS 条命令，协议 $(json '.data.protocolVersion')"
else
  fail "caps" "命令数不足（${CMDS}），或协议字段缺失"
fi

rpc revision
if ok_true && [[ "$(json '.data.revision')" =~ ^[0-9]+$ ]]; then
  pass "revision = $(json '.data.revision')"
else
  fail "revision"
fi

rpc project list
if ok_true; then
  pass "project list — $(json '.data.projects | length') 个工程"
else
  fail "project list"
fi

# ---------------------------------------------------------------- 2. 空工程写路径
echo
echo "2. 写路径（建空工程 → 加 MIDI 轨 → 写音符 → 渲染）"

STAMP="$(date +%H%M%S)"
NAME="[smoke] $STAMP"

rpc project create "$NAME" --bpm 92 --beats-per-bar 4 --bars 16 --dry-run
if ok_true && [ "$(json '.data.wouldCreate')" != "null" ]; then
  pass "project create --dry-run"
else
  fail "project create --dry-run" "dry-run 应该返回 wouldCreate 而不落盘"
fi

rpc project create "$NAME" --bpm 92 --beats-per-bar 4 --bars 16
NEW_PROJECT="$(json '.data.project.id')"
if ok_true && [[ "$NEW_PROJECT" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  pass "project create — $NEW_PROJECT"
else
  fail "project create" "没有拿到工程 id（App 侧 waitForProjectLoad 可能超时）"
fi

rpc track add --kind midi --name "Smoke Pad"
NEW_TRACK="$(json '.data.track.token // empty')"
if ok_true && [ -n "$NEW_TRACK" ]; then
  pass "track add — $NEW_TRACK"
else
  fail "track add" "没有拿到新轨 token"
fi

if [ -n "$NEW_TRACK" ]; then
  cat > /tmp/smoke-notes.json <<'JSON'
[
  {"start": 0, "duration": 1, "pitch": "C4", "velocity": 0.8},
  {"start": 1, "duration": 1, "pitch": "E4", "velocity": 0.8},
  {"start": 2, "duration": 1, "pitch": "G4", "velocity": 0.8},
  {"start": 3, "duration": 1, "pitch": "C5", "velocity": 0.8}
]
JSON
  rpc notes replace --track "$NEW_TRACK" --notes @/tmp/smoke-notes.json
  ok_true && pass "notes replace — 4 个音符" || fail "notes replace"

  rpc notes get --track "$NEW_TRACK"
  N="$(json '.data.notes | length')"
  [ "${N:-0}" -eq 4 ] && pass "notes get 回读到 4 个音符" || fail "notes get" "回读 $N 个，写进去是 4 个"

  rpc track render "$NEW_TRACK"
  ok_true && pass "track render" || fail "track render" "渲染失败（合成器 / PSOLA 路径）"
fi

# ---------------------------------------------------------------- 3. 走带与循环
echo
echo "3. 走带 / 循环"

rpc transport seek 2.5
ok_true && pass "transport seek 2.5s" || fail "transport seek"

rpc transport position
POS="$(printf '%s' "$LAST_OUT" | jq -r '[.. | numbers | select(. > 2 and . < 3)] | first // empty' 2>/dev/null)"
[ -n "$POS" ] && pass "transport position ≈ ${POS}s" || fail "transport position" "没读回 2.5 秒附近的位置"

rpc transport play
ok_true && pass "transport play" || fail "transport play"
sleep 0.4
rpc transport pause
ok_true && pass "transport pause" || fail "transport pause"

rpc loop set --a 1:1 --b 2:1
ok_true && pass "loop set 1:1 → 2:1" || fail "loop set" "空工程可能没有节拍网格（beat.set 先设 BPM）"

rpc loop get
# `loop get` 的 a/b 是秒数（数字），条形标签在 aBar/bBar
A="$(json '.data.a')"
[ "$A" != "null" ] && [ -n "$A" ] && pass "loop get — A=${A}s ($(json '.data.aBar'))" || fail "loop get" "A 点没落上"

rpc loop clear
ok_true && pass "loop clear" || fail "loop clear"

# ---------------------------------------------------------------- 4. 导出与质检
echo
echo "4. 导出 / 质检"

rpc export mix
MIX_PATH="$(json '.data.files[0] // empty')"
if [ -z "$MIX_PATH" ]; then
  # 兼容别的形状：递归找第一个像音频/视频的路径
  MIX_PATH="$(printf '%s' "$LAST_OUT" | jq -r '[.. | strings | select(test("\\.(wav|m4a|mov)$"))] | first // empty' 2>/dev/null)"
fi
if ok_true && [ -n "$MIX_PATH" ]; then
  pass "export mix — $(basename "$MIX_PATH")"
else
  fail "export mix" "没有拿到导出文件路径"
fi

rpc qc mix
QOK="$(json '.data.ok // .data.checks.ok')"
PEAK="$(json '.data.peakDbfs // .data.peak')"
if ok_true && [ "$QOK" != "null" ]; then
  pass "qc mix — ok=${QOK}，peak=${PEAK} dBFS"
else
  fail "qc mix" "质检返回缺少 ok / peakDbfs"
fi

# ---------------------------------------------------------------- 5. 错误路径
if [ "$ERRORS" -eq 1 ]; then
  echo
  echo "5. 错误路径（退出码契约）"

  LAST_OUT="$(ACAPELLA_AGENT_TOKEN=wrong-token "$BIN" ping 2>/dev/null)"; LAST_CODE=$?
  [ "$LAST_CODE" -eq 3 ] && pass "错 token → 退出码 3" || fail "错 token → 退出码 3" "实际 $LAST_CODE"

  REV="$(rpc revision; json '.data.revision')"
  LAST_OUT="$("$BIN" transport seek 1 --if-revision 0 --envelope 2>/dev/null)"; LAST_CODE=$?
  if [ "${REV:-0}" -gt 0 ] && [ "$LAST_CODE" -eq 4 ]; then
    pass "过期 ifRevision → 退出码 4（当前 revision ${REV}）"
  else
    fail "过期 ifRevision → 退出码 4" "实际 $LAST_CODE"
  fi

  LAST_OUT="$("$BIN" project delete not-a-project --confirm --envelope 2>/dev/null)"; LAST_CODE=$?
  [ "$LAST_CODE" -eq 6 ] && pass "不存在的工程 → 退出码 6" || fail "不存在的工程 → 退出码 6" "实际 $LAST_CODE"
fi

# ---------------------------------------------------------------- 清理
echo
if [ -n "$NEW_PROJECT" ] && [ "$KEEP" -eq 0 ]; then
  rpc project delete "$NEW_PROJECT" --confirm
  ok_true && pass "project delete — 清理测试工程" || fail "project delete" "测试工程没删掉，记得手动删 $NAME"
elif [ -n "$NEW_PROJECT" ]; then
  echo "  保留测试工程「${NAME}」($NEW_PROJECT)"
fi

# ---------------------------------------------------------------- 汇总
echo
if [ "$STEP_FAILED" -eq 0 ]; then
  echo "smoke: PASS（$STEP_TOTAL 项）"
  exit 0
fi
echo "smoke: FAIL（$STEP_FAILED/$STEP_TOTAL 项失败）"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
echo
echo "定位建议："
echo "  · 全部失败且退出码 3  → App 没开 AI 控制，或 token 不匹配（重启 App 会轮换 token）"
echo "  · 只有写路径失败      → 看 App 控制台里 [AgentControl] 的日志"
echo "  · 时序类（create/render/export 超时）→ 大概率是 App 侧等待条件没等到，查对应 handler"
exit 1
