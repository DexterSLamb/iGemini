#!/usr/bin/env bash
# ============================================================================
# scripts/linux/setup.sh — Linux(Deepin/Debian 系)一键部署 iGemini
#
#   把「白标 claudecodeui + Claude Code + DeepSeek 后端 + 五大能力工具链」
#   装到 ~/igemini，配 CLAUDE_CONFIG_DIR 隔离 + systemd 用户服务自启。
#   幂等：可重复运行（已装的步骤自动跳过）。
#
# 用法:
#   bash setup.sh                              # 全量部署（直连）
#   PROXY=http://127.0.0.1:7897 bash setup.sh  # 经代理拉 NodeSource/GitHub（国内强烈建议）
#   bash setup.sh --start                      # 部署完顺带启动服务
#   bash setup.sh --force                      # 强制重克隆/重建 claudecodeui
#
# 🔑 密钥不在本脚本里（绝不入库）。部署后把 key 写进 ~/.config 再启动：
#     ~/.config/deepseek/key          (DeepSeek，必填)
#     ~/.config/deepseek/serper_key   (Serper，可选，联网搜索兜底)
#     ~/.config/qwen/key  +  ~/.config/qwen/base   (Qwen，看图/OCR)
#
# 隔离铁律：本脚本只读仓库内 scripts/linux/* 与 vendor/igemini-claudecodeui.patch，
#           只写用户家目录（~/igemini、~/.config、~/.claude-igemini、~/.npm-global、~/.local）
#           与系统包（apt）。绝不动 mac/win 的代码或资源。
# ============================================================================
set -euo pipefail

# ---- 路径与常量 ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP="$HOME/igemini"
CC="$APP/claudecodeui"
CFG_DIR="$HOME/.claude-igemini"            # CC 的隔离配置目录
NPM_PREFIX="$HOME/.npm-global"             # claude 全局装这里（/usr 只读）

CCUI_REPO="https://github.com/siteboon/claudecodeui"
CCUI_COMMIT="4712431be81718dfb559ef43d7d7d5315bf4e01a"   # 与白标 patch 对齐
PATCH="$REPO_ROOT/vendor/igemini-claudecodeui.patch"

NODE_MAJOR_MIN=20            # vite7 等要求 node ≥20.19，低于则装 NodeSource 24
NODE_NODESOURCE="24"
NPM_MIRROR="https://registry.npmmirror.com"
PIP_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
PROXY="${PROXY:-}"          # 为空=直连；设了就给 NodeSource/GitHub 走代理

DO_START=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --start) DO_START=1 ;;
    --force) FORCE=1 ;;
    *) echo "未知参数: $a"; exit 2 ;;
  esac
done

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok(){  printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die(){ printf '  \033[0;31m✗ %s\033[0m\n' "$*"; exit 1; }

curl_p(){ curl ${PROXY:+-x "$PROXY"} -fsSL "$@"; }   # 走代理（如设了 PROXY）的 curl

# ---- 0) 预检 ----
say "0/10 预检"
command -v apt-get >/dev/null || die "本脚本针对 Debian 系（apt）。当前系统不支持。"
command -v git  >/dev/null || die "缺 git"
command -v curl >/dev/null || die "缺 curl"
command -v python3 >/dev/null || die "缺 python3"
[ -f "$PATCH" ] || die "找不到白标 patch: $PATCH"
sudo -v || die "需要 sudo 权限装系统包"
if command -v deepin-immutable-ctl >/dev/null 2>&1; then
  warn "检测到 Deepin 磐石不可变系统：/usr 只读，但 apt 装的包会提交进 ostree 部署、重启保留（已实测）。"
fi
ok "预检通过（PROXY=${PROXY:-直连}）"

# ---- 1) Node（≥20.19，否则装 NodeSource 24）----
say "1/10 Node"
need_node=1
if command -v node >/dev/null 2>&1; then
  ver="$(node -v | sed 's/v//')"; maj="${ver%%.*}"; min="$(echo "$ver" | cut -d. -f2)"
  if [ "$maj" -gt "$NODE_MAJOR_MIN" ] || { [ "$maj" -eq "$NODE_MAJOR_MIN" ] && [ "$min" -ge 19 ]; }; then
    need_node=0; ok "已有 node v$ver（满足 ≥20.19）"
  else
    warn "node v$ver 太旧（vite7 要 ≥20.19），将装 NodeSource $NODE_NODESOURCE"
  fi
fi
if [ "$need_node" = 1 ]; then
  sudo mkdir -p /etc/apt/keyrings   # 磐石下 /usr 只读，密钥放可写的 /etc
  curl_p "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_NODESOURCE}.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  if [ -n "$PROXY" ]; then   # 仅给 nodesource 走代理，其余 apt 源仍直连
    printf 'Acquire::https::Proxy::deb.nodesource.com "%s";\n' "$PROXY" | sudo tee /etc/apt/apt.conf.d/99nodesource-proxy >/dev/null
  fi
  sudo apt-get update -qq
  sudo apt-get install -y nodejs
  ok "node $(node -v) / npm $(npm -v)"
fi
npm config set registry "$NPM_MIRROR" >/dev/null; ok "npm registry → npmmirror"

# ---- 2) claudecodeui：克隆@定版 + 白标 patch + npm ci + build + bypass 补丁 + 标题 + prune ----
say "2/10 claudecodeui（白标构建）"
if [ -d "$CC/dist-server" ] && [ "$FORCE" = 0 ]; then
  ok "已构建（$CC/dist-server 存在），跳过。重建用 --force"
else
  rm -rf "$CC"; mkdir -p "$CC"; cd "$CC"
  git init -q && git remote add origin "$CCUI_REPO"
  GIT_SSL_NO_VERIFY=0 ${PROXY:+https_proxy=$PROXY http_proxy=$PROXY} git fetch --depth 1 origin "$CCUI_COMMIT" -q
  git checkout -q FETCH_HEAD
  ok "克隆 @ $(git rev-parse --short HEAD)"
  git apply --binary "$PATCH"; ok "白标 patch 已套用"
  # bug#1 修（Linux 侧补丁，不进共享 patch）：让会话发现/命名认 CLAUDE_CONFIG_DIR（改 .ts 源，须在 build 前）。
  # 否则隔离（CLAUDE_CONFIG_DIR=~/.claude-igemini）下仍读 homedir/.claude → 取不到会话名 → 侧栏全 "New Session"。
  python3 - "$CC/server" <<'PYEOF'
import sys, os
base = sys.argv[1]
edits = {
  'modules/providers/list/claude/claude-session-synchronizer.provider.ts':
    ("path.join(os.homedir(), '.claude')",
     "(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'))"),
  'modules/providers/services/sessions-watcher.service.ts':
    ("path.join(os.homedir(), '.claude', 'projects')",
     "path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'projects')"),
}
for rel,(old,new) in edits.items():
    p = os.path.join(base, rel); s = open(p, encoding='utf-8').read()
    assert old in s, "CLAUDE_CONFIG_DIR 补丁模式没找到（上游可能变了）: "+rel
    open(p,'w',encoding='utf-8').write(s.replace(old, new, 1))
print("  会话发现 → 认 CLAUDE_CONFIG_DIR（synchronizer + watcher）")
PYEOF
  # npm ci 不走代理（npmmirror 国内直连；代理会触发 npm 旧版 HttpsProxyAgent bug）
  npm ci; ok "npm ci 完成"
  npm run build; ok "build 完成（dist + dist-server）"
  # bypass-permissions：让网页里 CC 跑 bash 工具不被权限拦（Linux 侧补丁，不进共享 patch）
  python3 - "$CC/dist-server/server/claude-sdk.js" <<'PYEOF'
import sys
f=sys.argv[1]; s=open(f,encoding="utf-8").read()
old="if (settings.skipPermissions && permissionMode !== 'plan') {"
new="if (permissionMode !== 'plan') { // [iGemini] always bypass permissions (Linux)"
if "[iGemini] always bypass" in s: print("  bypass 补丁已在，跳过")
elif old in s: open(f,"w",encoding="utf-8").write(s.replace(old,new)); print("  bypass-permissions 补丁已套用")
else: print("  ! 未匹配 skipPermissions 原串（上游可能变了，需人工确认）")
PYEOF
  # bug#1 watcher 回归修复（绿点/loading）：会话发现认了 CLAUDE_CONFIG_DIR 后，watcher 会对【正在跑的当前会话】
  # 广播不含运行态的 upsert → 冲掉前端绿点/loading。用 isClaudeSDKSessionActive 抑制。
  python3 - "$CC/dist-server/server/modules/providers/services/sessions-watcher.service.js" <<'PYEOF'
import sys; p=sys.argv[1]; s=open(p,encoding="utf-8").read()
imp="import { generateDisplayName } from '../../../modules/projects/index.js';"
loop="for (const updatedSessionId of queuedUpdate.updatedSessionIds) {"
assert imp in s and loop in s, "watcher 锚点没找到（上游可能变了）"
if "isClaudeSDKSessionActive" not in s:
    s=s.replace(imp, imp+"\nimport { isClaudeSDKSessionActive } from '../../../claude-sdk.js';",1)
if "isClaudeSDKSessionActive(updatedSessionId)" not in s:
    s=s.replace(loop, loop+"\n            if (isClaudeSDKSessionActive(updatedSessionId)) { continue; } // [iGemini] 正在跑的会话别广播 upsert，避免冲掉运行态(绿点/loading)",1)
    open(p,"w",encoding="utf-8").write(s); print("  watcher suppress-active 修复已套")
else: print("  watcher 修复已在，跳过")
PYEOF
  # Shell 终端免权限：buildShellCommand 拼的 claude 命令没带 --dangerously-skip-permissions
  # → 网页 Shell 终端跑 claude 会不停问权限（Chat 走 SDK 已 bypass，唯独 Shell 这条漏了）。
  python3 - "$CC/dist-server/server/modules/websocket/services/shell-websocket.service.js" <<'PYEOF'
import sys; p=sys.argv[1]; s=open(p,encoding="utf-8").read()
F=" --dangerously-skip-permissions"
reps=[
 ("const command = initialCommand || 'claude';",
  "const command = initialCommand || 'claude"+F+"';"),
 ('claude --resume "${resumeSessionId}"; if ($LASTEXITCODE -ne 0) { claude }',
  'claude'+F+' --resume "${resumeSessionId}"; if ($LASTEXITCODE -ne 0) { claude'+F+' }'),
 ('claude --resume "${resumeSessionId}" || claude',
  'claude'+F+' --resume "${resumeSessionId}" || claude'+F),
]
if "[iGemini] shell bypass" not in s:
    n=0
    for old,new in reps:
        if old in s: s=s.replace(old,new,1); n+=1
    s=s.replace("function buildShellCommand","// [iGemini] shell bypass\nfunction buildShellCommand",1)
    open(p,"w",encoding="utf-8").write(s); print("  shell-websocket claude bypass 已套（%d/3 处；Shell 终端免权限）"%n)
else: print("  shell bypass 已在，跳过")
PYEOF
  # JWT 有效期 7d → 3650d：壳只在启动时自动登录一次、不续签，7 天后 token 过期 → 聊天 WS 鉴权失败。
  # 本机 / 固定账号 iGemini/iGemini 场景下长效 token 无实际危害；将来做远程鉴权改造时再收回。
  python3 - "$CC/dist-server/server/middleware/auth.js" <<'PYEOF'
import sys; f=sys.argv[1]; s=open(f,encoding="utf-8").read()
if "expiresIn: '3650d'" in s: print("  JWT 有效期已改，跳过")
elif "expiresIn: '7d'" in s:
    open(f,"w",encoding="utf-8").write(s.replace("expiresIn: '7d'","expiresIn: '3650d'")); print("  JWT 有效期 7d → 3650d")
else: print("  ! JWT expiresIn 锚点没找到（上游可能变了，需人工确认）")
PYEOF
  # 标题白标补漏：index.html <title> CloudCLI UI → iGemini（白标 patch 漏了这处）
  sed -i 's|<title>CloudCLI UI</title>|<title>iGemini</title>|' dist/index.html index.html 2>/dev/null || true
  npm prune --omit=dev >/dev/null 2>&1 || npm prune --production >/dev/null 2>&1 || true
  ok "prune devDeps 完成（node_modules 瘦身）"
fi

# ---- 3) Claude Code CLI（npm 家前缀，因 /usr 只读）----
say "3/10 Claude Code CLI"
npm config set prefix "$NPM_PREFIX" >/dev/null
if "$NPM_PREFIX/bin/claude" --version >/dev/null 2>&1; then
  ok "已装 claude $($NPM_PREFIX/bin/claude --version 2>/dev/null | head -1)"
else
  npm i -g @anthropic-ai/claude-code
  ok "claude $($NPM_PREFIX/bin/claude --version 2>/dev/null | head -1)"
fi

# ---- 4) 系统能力工具（apt）----
say "4/10 系统工具（pandoc / chromium / tesseract）"
sudo apt-get install -y pandoc tesseract-ocr tesseract-ocr-chi-sim >/dev/null
sudo apt-get install -y chromium >/dev/null 2>&1 || sudo apt-get install -y chromium-browser >/dev/null 2>&1 || warn "chromium 装失败，md2pdf 不可用"
for b in pandoc tesseract chromium; do command -v "$b" >/dev/null 2>&1 && ok "$b: $(command -v "$b")"; done

# ---- 5) Python 依赖（用户区，过 PEP668，国内镜像）----
say "5/10 Python 依赖"
pip install --user --break-system-packages -i "$PIP_MIRROR" \
  PyMuPDF pdfplumber python-docx openpyxl markdown pandas >/dev/null
python3 -c "import fitz,pdfplumber,docx,openpyxl,markdown,pandas" \
  && ok "fitz/pdfplumber/docx/openpyxl/markdown/pandas import OK" || die "Python 依赖 import 失败"

# ---- 6) 能力工具 + 无扩展名软链 ----
say "6/10 能力工具 → $APP/tools"
mkdir -p "$APP/tools"
cp "$SCRIPT_DIR/tools/"*.py "$APP/tools/"
chmod +x "$APP/tools/"*.py
( cd "$APP/tools"; for t in parsedoc websearch describe-image md2docx md2pdf; do ln -sf "$t.py" "$t"; done )
ok "5 个工具 + 软链就位"

# ---- 7) 启动器 ----
say "7/10 启动器 start-web.sh"
cp "$SCRIPT_DIR/start-web.sh" "$APP/start-web.sh"; chmod +x "$APP/start-web.sh"
ok "$APP/start-web.sh"

# ---- 8) 隔离配置目录 + 部署版 CLAUDE.md ----
say "8/10 CLAUDE_CONFIG_DIR 隔离 + CLAUDE.md"
mkdir -p "$CFG_DIR" "$HOME/.config/deepseek" "$HOME/.config/qwen"
cp "$SCRIPT_DIR/deployed-claude-md.md" "$CFG_DIR/CLAUDE.md"
ok "$CFG_DIR/CLAUDE.md（仅 iGemini 的 claude 读，不碰日常 ~/.claude）"

# ---- 9) systemd 用户服务（开机自启 + linger）----
say "9/10 systemd 用户服务"
mkdir -p "$HOME/.config/systemd/user"
cp "$SCRIPT_DIR/igemini-web.service" "$HOME/.config/systemd/user/igemini-web.service"
systemctl --user daemon-reload
systemctl --user enable igemini-web >/dev/null 2>&1 || true
sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || warn "enable-linger 失败（无登录时可能不自启）"
ok "igemini-web 已 enable + linger（开机自启）"

# ---- 10) 密钥检查 + 收尾 ----
say "10/10 密钥检查"
miss=0
[ -s "$HOME/.config/deepseek/key" ] && ok "DeepSeek key 已就位" || { warn "缺 DeepSeek key → ~/.config/deepseek/key（必填，AI 不可用）"; miss=1; }
[ -s "$HOME/.config/qwen/key" ]     && ok "Qwen key 已就位"     || warn "缺 Qwen key → ~/.config/qwen/{key,base}（看图/OCR 不可用）"
[ -s "$HOME/.config/deepseek/serper_key" ] && ok "Serper key 已就位" || warn "缺 Serper key → ~/.config/deepseek/serper_key（搜索兜底，可选）"

if [ "$DO_START" = 1 ]; then
  if [ "$miss" = 1 ]; then warn "DeepSeek key 缺失，跳过启动"; else
    systemctl --user restart igemini-web; sleep 3
    say "启动结果"
    echo -n "  is-active: "; systemctl --user is-active igemini-web || true
    curl -m 6 -sS -o /dev/null -w "  curl http://127.0.0.1:8888 → http=%{http_code}\n" http://127.0.0.1:8888/ || true
  fi
fi

say "完成"
echo "  服务:   systemctl --user {start,status,restart} igemini-web"
echo "  访问:   http://127.0.0.1:8888  （桌面浏览器；可加主屏成 iGemini PWA）"
echo "  日志:   journalctl --user -u igemini-web -f"
[ "$miss" = 1 ] && echo "  ⚠️  先写 DeepSeek key 到 ~/.config/deepseek/key 再 restart 服务，AI 才可用。"
