#!/usr/bin/env bash
# start-web.sh — Linux(Deepin)启动器:注入 DeepSeek env + CLAUDE_CONFIG_DIR 隔离,起 claudecodeui 网页服务。
# 由 systemd user 服务 igemini-web 调用。绑 127.0.0.1:8888。key 从 ~/.config 读,绝不硬编码。
set -u
APP="$HOME/igemini"; CC="$APP/claudecodeui"
LOG="${TMPDIR:-/tmp}/igemini-web.log"
note(){ echo "$(date +%H:%M:%S)  $*" >> "$LOG"; }

# PATH:自带 claude(npm 家前缀)、能力工具、pip 用户脚本、系统 node(/usr/bin)
export PATH="$HOME/.npm-global/bin:$APP/tools:$HOME/.local/bin:$PATH"

# ---- DeepSeek 后端(key 从 ~/.config/deepseek/key 读)----
# base 地址【可配置】:~/.config/deepseek/base 存在则用它,否则缺省 DeepSeek 官方。
# 为将来「切换后端」留位——届时只改这个文件(地址指向新端点),
# 代码一行不动。与 macOS start-web.sh / Windows run-server.ps1 一致。
BASEF="$HOME/.config/deepseek/base"
if [ -s "$BASEF" ]; then
  export ANTHROPIC_BASE_URL="$(tr -d '\r\n' < "$BASEF")"
else
  export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
fi
KEYF="$HOME/.config/deepseek/key"
[ -f "$KEYF" ] && export ANTHROPIC_AUTH_TOKEN="$(tr -d '\r\n' < "$KEYF")"
[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && note "警告:DeepSeek key 缺失($KEYF)——AI 不可用,请写入后重启服务"
unset ANTHROPIC_API_KEY
export ANTHROPIC_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-pro[1m]"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_EFFORT_LEVEL="max"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_INSTALLATION_CHECKS=1
export DISABLE_AUTOUPDATER=1

# ---- claude 引擎路径 + 【隔离配置目录】(与日常官方 claude 井水不犯河水)----
export CLAUDE_CLI_PATH="$HOME/.npm-global/bin/claude"
export CLAUDE_CONFIG_DIR="$HOME/.claude-igemini"

# ---- 只绑本机;端口 8888 ----
export HOST="127.0.0.1"
export SERVER_PORT="8888"

cd "$CC" || { note "致命:claudecodeui 缺失($CC)"; exit 1; }
note "启动 base=$ANTHROPIC_BASE_URL model=$ANTHROPIC_MODEL listen=$HOST:$SERVER_PORT cfg=$CLAUDE_CONFIG_DIR claude=$CLAUDE_CLI_PATH"
exec node dist-server/server/index.js
