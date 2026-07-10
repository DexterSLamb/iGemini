#!/bin/bash
# claudecodeui(CloudCLI)网页层启动器 —— 模型后端走 DeepSeek（复用同目录 ds.sh 的环境）。
# 放在与 ds.sh、claudecodeui/ 同一目录运行（部署机上即 ~/Documents/ClaudeCode/）。
# 由 launchd LaunchAgent 调用（见 com.cloudcli.deepseek.plist.template）。

HERE="$(cd "$(dirname "$0")" && pwd)"
DSCONF="${DS_SH:-$HERE/ds.sh}"
CCUI="${CCUI_DIR:-$HERE/claudecodeui}"

# 1) 复用 ds.sh 的 DeepSeek 环境（AUTH_TOKEN / 模型路由 / unset API_KEY），不重复存 key
[ -f "$DSCONF" ] && eval "$(grep -E '^(export (ANTHROPIC|CLAUDE_CODE)_|unset ANTHROPIC_API_KEY)' "$DSCONF")"

# 2) node 走 nvm（非交互/launchd 环境 PATH 不全，显式 source）
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# 3) 让 CloudCLI 找得到 claude（关键：非交互/launchd 的 PATH 不含 /usr/local/bin）
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
for c in /usr/local/bin/claude /opt/homebrew/bin/claude "$HOME/.local/bin/claude"; do
  [ -z "$CLAUDE_BIN" ] && [ -x "$c" ] && CLAUDE_BIN="$c"
done
if [ -n "$CLAUDE_BIN" ]; then
  export PATH="$(dirname "$CLAUDE_BIN"):$PATH"
  export CLAUDE_CLI_PATH="$CLAUDE_BIN"
fi

# 4) 网页服务：默认只绑本机；SERVER_PORT 避开浏览器禁用端口(如 6666)，勿用 <1024(需 root)
export HOST="${HOST:-127.0.0.1}"
export SERVER_PORT="${SERVER_PORT:-8888}"

cd "$CCUI" || { echo "找不到 claudecodeui: $CCUI"; exit 1; }
echo "后端: ${ANTHROPIC_BASE_URL:-?} | 模型: ${ANTHROPIC_MODEL:-?} | claude: ${CLAUDE_CLI_PATH:-(PATH)}"
echo "监听: $HOST:$SERVER_PORT"
exec npm run server
