#!/bin/bash
# iGemini macOS 启动器:注入 DeepSeek env + 用自带 node/claude/工具/python/chromium,起 claudecodeui 网页服务。
# 由 launchd LaunchAgent 调用;相对自身定位(装到 /Applications/iGemini 即可)。key 从 ~/.config 读,绝不硬编码。
IG="$(cd "$(dirname "$0")" && pwd)"
LOG="${TMPDIR:-/tmp}/igemini-web.log"
note(){ echo "$(date +%H:%M:%S)  $*" >> "$LOG"; }
export PATH="$IG/python/bin:$IG/runtime/node/bin:$IG/bin:$IG/tools:$PATH"
export IGEMINI_CHROME="$(ls "$IG"/chromium/chrome-headless-shell-mac-*/chrome-headless-shell 2>/dev/null | head -1)"
# ---- 首次运行:无 DeepSeek key 时【阻塞等待】key 出现（key 由原生壳的填 key 窗收集写入，不再弹 tkinter）----
# 阻塞而非 keyless 起 node：避免"没 key 也起来了、聊天却报鉴权错"，也避免 launchd KeepAlive 崩溃循环。
# 壳写入 key 后会 kickstart 本服务，被杀重启 → 此时 key 已在 → 直接往下跑。
mkdir -p "$HOME/.claude-igemini"
[ -f "$IG/CLAUDE.md" ] && cp "$IG/CLAUDE.md" "$HOME/.claude-igemini/CLAUDE.md"
while [ ! -s "$HOME/.config/deepseek/key" ]; do sleep 1; done
# ---- DeepSeek 后端 ----
# base 地址【可配置】：~/.config/deepseek/base 存在则用它，否则缺省 DeepSeek 官方。
# 为未来「切换后端」留位——届时只改这个文件的内容(地址指向新端点)，
# 本地代码一行不用改、包不用重出。
BASEF="$HOME/.config/deepseek/base"
if [ -s "$BASEF" ]; then
  export ANTHROPIC_BASE_URL="$(tr -d '\r\n' < "$BASEF")"
else
  export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
fi
KEYF="$HOME/.config/deepseek/key"
[ -f "$KEYF" ] && export ANTHROPIC_AUTH_TOKEN="$(tr -d '\r\n' < "$KEYF")"
[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && note "警告:DeepSeek key 缺失($KEYF)——填好后重启服务"
unset ANTHROPIC_API_KEY
export ANTHROPIC_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_INSTALLATION_CHECKS=1 DISABLE_AUTOUPDATER=1
# ---- claude 引擎 + 隔离配置目录(与日常 claude 互不犯)----
# 直接指平台二进制（claude-code-darwin-<arch>/claude），绕开 .bin/claude launcher
# —— 该 launcher 依赖 postinstall 布置，跨 arch（--cpu x64 在 arm64 机上）装会失败 → spawn ENOEXEC
export CLAUDE_CLI_PATH="$(ls "$IG"/claude-pkg/node_modules/@anthropic-ai/claude-code-darwin-*/claude 2>/dev/null | head -1)"
# bug#2 修：把 claude 二进制目录加进 PATH —— 否则集成终端(Shell 标签)按名字敲 `claude` 找不到（command not found / exit 127）
[ -n "$CLAUDE_CLI_PATH" ] && export PATH="$(dirname "$CLAUDE_CLI_PATH"):$PATH"
export CLAUDE_CONFIG_DIR="$HOME/.claude-igemini"
# 预置 claude 引导完成标记：否则隔离配置是全新的，Shell 里跑 claude 会弹主题/信任向导，
# 还会挡住历史会话的 --resume（用户只看到引导、看不到对话）。合并、幂等、原子落盘。
"$IG/python/bin/python3" - <<'PY' 2>/dev/null || true
import json, os
cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude-igemini")
os.makedirs(cfg, exist_ok=True)
p = os.path.join(cfg, ".claude.json")
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: d = {}
if not isinstance(d, dict): d = {}        # 配置被写坏成非对象时兜底，避免下面赋值抛错
d["hasCompletedOnboarding"] = True
d.setdefault("theme", "dark"); d.setdefault("lastOnboardingVersion", "2.1.31")
tmp = p + ".tmp"                          # 原子落盘：先写临时文件再 rename，中途失败不损坏主配置
with open(tmp, "w") as f: json.dump(d, f)
os.replace(tmp, p)
PY
# 安全：必须显式钉死 127.0.0.1（只开本机、不上局域网）。index.js 里有 0.0.0.0 的默认路径，绝不能依赖默认值。
export HOST="127.0.0.1" SERVER_PORT="8888"
cd "$IG/claudecodeui" || { note "致命:claudecodeui 缺失($IG)"; exit 1; }
note "启动 base=$ANTHROPIC_BASE_URL model=$ANTHROPIC_MODEL listen=$HOST:$SERVER_PORT cfg=$CLAUDE_CONFIG_DIR claude=$CLAUDE_CLI_PATH"
# 服务起来后自动打开桌面壳（每次安装后弹一次；用户关掉后不再打扰，postinstall 会清标记重新触发）
( OF="$HOME/.config/igemini/.app-opened"; [ -f "$OF" ] && exit 0
  for i in $(seq 1 40); do /usr/bin/curl -s -o /dev/null "http://127.0.0.1:$SERVER_PORT/" 2>/dev/null && break; sleep 1; done
  /usr/bin/open -a "/Applications/iGemini.app" 2>/dev/null && { /bin/mkdir -p "$(dirname "$OF")"; /usr/bin/touch "$OF"; } ) &
exec node dist-server/server/index.js >> "$LOG" 2>&1
