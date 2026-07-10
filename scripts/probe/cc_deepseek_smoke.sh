#!/usr/bin/env bash
# 真实 Claude Code → DeepSeek v4-pro 多步工具任务冒烟测试（方案最终验证）。
# 完全隔离：临时 CLAUDE_CONFIG_DIR + 临时工作目录，绝不触碰 ~/.claude。
# 成本：一次真实多步 agent 运行，约几角钱。Key 不会被打印。
set -euo pipefail

# --- 读取 DeepSeek key（只读，不打印）---
KEY="${DEEPSEEK_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$HOME/.config/deepseek/key" ]; then
  KEY="$(grep -m1 '^sk-' "$HOME/.config/deepseek/key" || head -n1 "$HOME/.config/deepseek/key")"
fi
[ -n "$KEY" ] || { echo "未找到 DeepSeek key（DEEPSEEK_API_KEY 或 ~/.config/deepseek/key）"; exit 1; }

# --- 隔离的临时配置 + 工作目录 ---
TMP="$(mktemp -d)"
CFG="$TMP/config"; WORK="$TMP/work"
mkdir -p "$CFG" "$WORK"
echo "隔离目录：CLAUDE_CONFIG_DIR=$CFG"
echo "         WORKDIR=$WORK"
echo "（不触碰 ~/.claude；测试完可删：rm -rf \"$TMP\"）"
echo ""

# --- 仅本进程环境：把 CC 指向 DeepSeek ---
export CLAUDE_CONFIG_DIR="$CFG"
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
export ANTHROPIC_API_KEY="$KEY"
export ANTHROPIC_MODEL="deepseek-v4-pro"
export ANTHROPIC_SMALL_FAST_MODEL="deepseek-v4-flash"

TASK='Use your tools to do these steps in order:
1) Write a file a.txt containing exactly: alpha
2) Write a file b.txt containing exactly: beta
3) Write a file c.txt containing exactly: gamma
4) Run a bash command to concatenate a.txt, b.txt and c.txt (in that order) into poem.txt
5) Read poem.txt and report its contents.
Work only inside the current directory.'

echo "=== 运行真实 Claude Code（model=deepseek-v4-pro，多步工具）==="
cd "$WORK"
set +e
claude -p "$TASK" \
  --model deepseek-v4-pro \
  --permission-mode bypassPermissions \
  --allowedTools Write Edit Read Bash 2>&1
RC=$?
set -e

echo ""
echo "=== 结果校验 ==="
echo "exit code: $RC"
if [ -f "$WORK/poem.txt" ]; then
  echo "poem.txt 内容："; cat "$WORK/poem.txt"
  if grep -q "alpha" "$WORK/poem.txt" && grep -q "gamma" "$WORK/poem.txt"; then
    echo ""
    echo "✅ 成功：v4-pro 在真实 CC 的多轮工具循环里跑通，未触发 400。方案成立。"
  else
    echo "⚠️ poem.txt 存在但内容不完整——工具链部分生效，看上面输出定位。"
  fi
else
  echo "❌ 未生成 poem.txt——检查上面 CC 输出里是否有 HTTP 400 / 工具调用错误。"
fi
echo ""
echo "清理临时目录：rm -rf \"$TMP\""
