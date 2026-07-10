#!/usr/bin/env bash
# ============================================================================
# scripts/macos/installer/build-pkg.sh
#   在 arm64 Mac 上构建 iGemini macOS 离线胖包 .pkg，支持 arm64 与 x86_64(x64) 两种目标。
#   全程封闭在本目录，不碰系统/家目录的 claude / npm-global / python（用户日常环境零影响）。
#
# 用法（在 arm64 Mac + Xcode CLT 上）：
#   PROXY=http://127.0.0.1:7897 bash build-pkg.sh arm64    # Apple Silicon 包
#   PROXY=http://127.0.0.1:7897 bash build-pkg.sh x64      # Intel 包
#
#   外网二进制（github/codeload/googleapis/python-build-standalone）经 PROXY（默认本机代理 7897）；
#   node/npm/pip 走国内镜像（npmmirror / 清华），免翻墙。
#   产物：out/iGemini-Installer-<arch>-v<version>.pkg（版本号取自 installer/VERSION；已 gitignore，不入库）。
# ============================================================================
set -euo pipefail

ARCH="${1:-arm64}"
case "$ARCH" in
  arm64)       NODE_ARCH=arm64; PY_ARCH=aarch64; PANDOC_ARCH=arm64;  CHROME_ARCH=arm64; CLANG_ARCH=arm64;   PKG_HOST=arm64 ;;
  x64|x86_64)  ARCH=x64;  NODE_ARCH=x64; PY_ARCH=x86_64; PANDOC_ARCH=x86_64; CHROME_ARCH=x64;   CLANG_ARCH=x86_64; PKG_HOST=x86_64 ;;
  *) echo "用法: build-pkg.sh [arm64|x64]"; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# 构建工作目录放无空格路径（node-gyp 源码编译遇路径空格会失败；本仓在 "Claude Code/" 下有空格）
WORK="${IGBUILD_WORK:-/tmp/igbuild}/$ARCH"
CACHE="$WORK/cache"; STAGE="$WORK/staging"; PKGROOT="$WORK/pkgroot"; OUT="$HERE/out"
PX="${PROXY:-}"
PATCH="$REPO/vendor/igemini-claudecodeui.patch"
ICON="$REPO/assets/igemini-icon.png"
CCUI_REPO="siteboon/claudecodeui"
CCUI_COMMIT="4712431be81718dfb559ef43d7d7d5315bf4e01a"
NODE_CDN="https://cdn.npmmirror.com/binaries/node"
NPM_MIRROR="https://registry.npmmirror.com"
PIP_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok(){  printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
die(){ printf '  \033[0;31m✗ %s\033[0m\n' "$*"; exit 1; }
arch_of(){ file "$1" 2>/dev/null | grep -oE 'arm64|x86_64' | head -1; }
# 从 github 下载：国内镜像直连优先（避开代理对 github 的 SSL 重置），代理直连兜底
GHMIRRORS=( "https://ghfast.top/" "https://gh-proxy.com/" "https://github.moeyy.xyz/" "https://ghproxy.net/" )
dlgh(){  # $1=github完整URL  $2=目标文件
  local url="$1" dest="$2" m
  for m in "${GHMIRRORS[@]}"; do
    curl -m 240 -fsSL --retry 3 --retry-all-errors --http1.1 -o "$dest" "${m}${url}" 2>/dev/null && [ -s "$dest" ] && { printf '    (via %s)\n' "$m"; return 0; }
  done
  curl -m 240 -fsSL --retry 4 --retry-all-errors --http1.1 ${PX:+-x "$PX"} -o "$dest" "$url" 2>/dev/null && [ -s "$dest" ] && { echo "    (via 代理直连)"; return 0; }
  return 1
}
# 固定版本（避开 api.github.com 调用；可按需更新）
PANDOC_VER="3.10"; PY_TAG="20260623"; PY_VER="3.12.13"
MKVER="$(tr -d ' \t\r\n' < "$HERE/VERSION" 2>/dev/null)"; [ -n "$MKVER" ] || MKVER="1.0.0"   # 用户可见版本(单一真源: installer/VERSION)——贯穿 关于面板 / Info.plist / 包名
VER="$MKVER.$(date +%Y%m%d%H%M%S)"   # pkg 内部版本 = 营销版本.秒级时间戳 → 每次构建递增、绝不撞版本；安装器把每次安装都当新版本完整铺 payload（避免同版本重装跳过文件）

[ -f "$PATCH" ] || die "缺白标 patch: $PATCH"
command -v xcrun >/dev/null || die "缺 Xcode CLT(clang)"
mkdir -p "$CACHE" "$STAGE" "$OUT"

# 封闭 npm 环境（只在本脚本内生效，绝不碰 ~/.npm / ~/.npmrc / 系统 claude）
NPMENV=( "npm_config_cache=$CACHE/npm" "npm_config_userconfig=$CACHE/npmrc" "npm_config_globalconfig=$CACHE/npmrc-g"
         "npm_config_registry=$NPM_MIRROR" "npm_config_update_notifier=false" "npm_config_fund=false" )

echo "构建 iGemini macOS 安装包  目标=$ARCH  代理=${PX:-直连}"

# ---- 1) 可移植 node（目标 arch；只打包、构建用系统 node）----
say "1/12 node 24 darwin-$NODE_ARCH"
NF=$(curl -m 25 -fsSL --retry 6 --retry-all-errors --retry-delay 3 --http1.1 "$NODE_CDN/latest-v24.x/SHASUMS256.txt" | grep -oE "node-v24\.[0-9.]+-darwin-$NODE_ARCH\.tar\.gz" | head -1)
NV=$(echo "$NF" | grep -oE 'v24\.[0-9.]+')
[ -f "$CACHE/$NF" ] || curl -m 300 -fsSL --retry 6 --retry-all-errors --retry-delay 3 --http1.1 -o "$CACHE/$NF" "$NODE_CDN/$NV/$NF"
rm -rf "$STAGE/runtime/node"; mkdir -p "$STAGE/runtime/node"
tar -xzf "$CACHE/$NF" -C "$STAGE/runtime/node" --strip-components=1
ok "$NF  arch=$(arch_of "$STAGE/runtime/node/bin/node")"

# ---- 2) claude（目标 arch；封闭装、非 -g）----
say "2/12 Claude Code CLI（darwin-${NODE_ARCH}）"
rm -rf "$STAGE/claude-pkg"; mkdir -p "$STAGE/claude-pkg"
env "${NPMENV[@]}" npm install --prefix "$STAGE/claude-pkg" --cpu "$NODE_ARCH" --os darwin @anthropic-ai/claude-code >/dev/null
CLBIN=$(find "$STAGE/claude-pkg/node_modules/@anthropic-ai" -path "*darwin-$NODE_ARCH*/claude" -type f | head -1)
[ -n "$CLBIN" ] || die "没装到 claude-code-darwin-$NODE_ARCH 二进制"
ok "claude 二进制 arch=$(arch_of "$CLBIN")"

if [ -d "$STAGE/claudecodeui/dist-server" ]; then ok "claudecodeui 已构建，复用（跳过 3-5）"; else
# ---- 3) claudecodeui 源码（codeload tarball 经代理 + 套白标 patch）----
say "3/12 claudecodeui 源码 + 白标 patch"
TGZ="$CACHE/ccui.tgz"
[ -f "$TGZ" ] || dlgh "https://github.com/$CCUI_REPO/archive/$CCUI_COMMIT.tar.gz" "$TGZ" || die "claudecodeui 源码下载失败（镜像+代理都不通）"
tar -tzf "$TGZ" 2>/dev/null | grep -q package.json || die "claudecodeui 压缩包无效"
rm -rf "$STAGE/claudecodeui"; mkdir -p "$STAGE/claudecodeui"
tar -xzf "$TGZ" -C "$STAGE/claudecodeui" --strip-components=1
( cd "$STAGE/claudecodeui" && git init -q && git apply --binary "$PATCH" )
# bug#1 修（macOS 专属，不碰共享 patch）：让 claudecodeui 的会话发现/命名认 CLAUDE_CONFIG_DIR。
# 否则 macOS 隔离（CLAUDE_CONFIG_DIR=~/.claude-igemini）下，claudecodeui 仍读 homedir/.claude → 取不到会话名 → 侧栏全 "New Session"。
python3 - "$STAGE/claudecodeui/server" <<'PY'
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
print("已让 synchronizer + watcher 认 CLAUDE_CONFIG_DIR")
PY
ok "已套白标 patch（$(grep -m1 '"name"' "$STAGE/claudecodeui/package.json" | grep -oE '@[^"]+')） + CLAUDE_CONFIG_DIR 修复"

# ---- 4) npm ci（按构建机 arch 装；保证 build 工具 rollup/vite/esbuild 可在构建机上跑）----
say "4/12 npm ci"
( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm ci >/dev/null )
ok "依赖装好（构建机 arch；运行时原生模块稍后重建为目标 arch）"

# ---- 5) build（构建机 arch 工具）+ 运行时原生重建为目标 arch + bypass + 标题 + prune ----
say "5/12 build + 原生重建(${NODE_ARCH}) + 补丁 + prune"
( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm run build >/dev/null )
if [ "$NODE_ARCH" != "arm64" ]; then   # 构建机=arm64；目标非 arm64 → 把运行时原生模块(node-pty/better-sqlite3/bcrypt 等)重建为目标 arch
  ( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" \
      npm_config_arch="$NODE_ARCH" npm_config_target_arch="$NODE_ARCH" npm_config_nodedir="$STAGE/runtime/node" \
      npm rebuild >/dev/null )
  SQL=$(find "$STAGE/claudecodeui/node_modules/better-sqlite3" -name "*.node" 2>/dev/null | head -1)
  BCR=$(find "$STAGE/claudecodeui/node_modules/bcrypt" -name "*.node" 2>/dev/null | head -1)
  ok "运行时原生重建 → better-sqlite3:$(arch_of "$SQL")  bcrypt:$(arch_of "$BCR")"
fi
python3 - "$STAGE/claudecodeui/dist-server/server/claude-sdk.js" <<'PY'
import sys; f=sys.argv[1]; s=open(f,encoding="utf-8").read()
old="if (settings.skipPermissions && permissionMode !== 'plan') {"
new="if (permissionMode !== 'plan') { // [iGemini] always bypass permissions (macOS)"
if "[iGemini] always bypass" not in s and old in s:
    open(f,"w",encoding="utf-8").write(s.replace(old,new))
PY
# bug#1 watcher 回归修复（绿点/loading）：广播 session_upserted 前跳过【正在运行】的会话。
# bug#1 让 watcher 真去监 ~/.claude-igemini 后，聊天时它会对【正在跑的当前会话】广播一个不含运行态、
# messageCount=0 的 upsert → 冲掉前端的绿点/loading（卡死/错乱）。上游注释自承"无运行中抑制"，
# 该假设对【当前正在跑的会话本身】不成立；这里用 claude-sdk 的 isClaudeSDKSessionActive 补上抑制。
python3 - "$STAGE/claudecodeui/dist-server/server/modules/providers/services/sessions-watcher.service.js" <<'PY'
import sys; p=sys.argv[1]; s=open(p,encoding="utf-8").read()
imp="import { generateDisplayName } from '../../../modules/projects/index.js';"
loop="for (const updatedSessionId of queuedUpdate.updatedSessionIds) {"
assert imp in s and loop in s, "watcher 锚点没找到（上游可能变了）"
if "isClaudeSDKSessionActive" not in s:
    s=s.replace(imp, imp+"\nimport { isClaudeSDKSessionActive } from '../../../claude-sdk.js';",1)
if "isClaudeSDKSessionActive(updatedSessionId)" not in s:
    s=s.replace(loop, loop+"\n            if (isClaudeSDKSessionActive(updatedSessionId)) { continue; } // [iGemini] 正在跑的会话别广播 upsert，避免冲掉运行态(绿点/loading)",1)
open(p,"w",encoding="utf-8").write(s)
print("watcher suppress-active 修复已套")
PY
# [iGemini] Shell 终端免权限：buildShellCommand 拼的 claude 命令（新会话 / unix恢复 / win恢复，共 3 条）
# 都没带 --dangerously-skip-permissions → Shell 终端里跑 claude 会不停问权限（Chat 走 SDK 已 bypass，
# 唯独 Shell 这条漏了；全库审计确认 claude 仅经 SDK 与此 pty-shell 两路，故只此 3 条需补）。
python3 - "$STAGE/claudecodeui/dist-server/server/modules/websocket/services/shell-websocket.service.js" <<'PY'
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
    for old,new in reps:
        assert old in s, "shell bypass 锚点没找到（上游可能变了）: "+old[:42]
        s=s.replace(old,new,1)
    s=s.replace("function buildShellCommand","// [iGemini] shell bypass\nfunction buildShellCommand",1)
    open(p,"w",encoding="utf-8").write(s)
    print("shell-websocket claude bypass 已套（Shell 终端免权限）")
PY
sed -i '' 's|<title>CloudCLI UI</title>|<title>iGemini</title>|' "$STAGE/claudecodeui/dist/index.html" "$STAGE/claudecodeui/index.html" 2>/dev/null || true
( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" npm prune --omit=dev >/dev/null 2>&1 || true )
ok "dist + dist-server 就绪，已 bypass/标题/prune"
fi

# ---- 6) pandoc（目标 arch）----
say "6/12 pandoc $PANDOC_VER"
[ -f "$CACHE/pandoc.zip" ] || dlgh "https://github.com/jgm/pandoc/releases/download/$PANDOC_VER/pandoc-$PANDOC_VER-$PANDOC_ARCH-macOS.zip" "$CACHE/pandoc.zip" || die "pandoc 下载失败（镜像+代理都不通）"
rm -rf "$CACHE/pdx"; mkdir -p "$CACHE/pdx" "$STAGE/bin"; unzip -oq "$CACHE/pandoc.zip" -d "$CACHE/pdx"
cp "$(find "$CACHE/pdx" -name pandoc -type f -perm +111 | head -1)" "$STAGE/bin/pandoc"; chmod +x "$STAGE/bin/pandoc"
ok "pandoc $PANDOC_VER  arch=$(arch_of "$STAGE/bin/pandoc")"

# ---- 7) python-build-standalone（目标 arch）+ pip 依赖 ----
say "7/12 python $PY_VER + 五大能力依赖"
[ -f "$CACHE/python.tgz" ] || dlgh "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG/cpython-$PY_VER+$PY_TAG-$PY_ARCH-apple-darwin-install_only.tar.gz" "$CACHE/python.tgz" || die "python 下载失败（镜像+代理都不通）"
rm -rf "$STAGE/python"; mkdir -p "$STAGE/python"; tar -xzf "$CACHE/python.tgz" -C "$STAGE/python" --strip-components=1
"$STAGE/python/bin/python3" -m pip install --no-warn-script-location --disable-pip-version-check --only-binary=:all: -i "$PIP_MIRROR" \
  PyMuPDF pdfplumber python-docx openpyxl markdown pandas >/dev/null
"$STAGE/python/bin/python3" -c "import fitz,pdfplumber,docx,openpyxl,markdown,pandas" || die "python 依赖 import 失败"
ok "python $("$STAGE/python/bin/python3" -V 2>&1)  依赖齐  arch=$(arch_of "$STAGE/python/bin/python3.12" 2>/dev/null || arch_of "$(ls "$STAGE"/python/lib/python3.12/lib-dynload/*.so 2>/dev/null|head -1)")"

# ---- 8) WKWebView 壳（clang -arch；ad-hoc 签名）----
say "8/12 iGemini.app（${CLANG_ARCH}）"
WSRC="$HERE/../cloudcli-webkit"; APP="$STAGE/iGemini.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -arch "$CLANG_ARCH" -mmacosx-version-min=12.0 -fobjc-arc "$WSRC/main.m" -framework Cocoa -framework WebKit -o "$APP/Contents/MacOS/iGemini"
cp "$WSRC/Info.plist" "$APP/Contents/Info.plist"
# 版本号以 VERSION 文件为单一真源钉进 app（关于面板读 CFBundleShortVersionString）——免得 Info.plist 手改漏了对不上
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MKVER" -c "Set :CFBundleVersion $MKVER" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
[ -f "$WSRC/icon.icns" ] && cp "$WSRC/icon.icns" "$APP/Contents/Resources/icon.icns"
for L in en zh-Hans; do [ -d "$WSRC/$L.lproj" ] && cp -R "$WSRC/$L.lproj" "$APP/Contents/Resources/"; done
xattr -cr "$APP"; codesign --force --deep -s - "$APP" 2>/dev/null
ok "壳 arch=$(arch_of "$APP/Contents/MacOS/iGemini")  已 ad-hoc 签名"

# ---- 9) chrome-headless-shell（目标 arch；md2pdf 用）----
say "9/12 chrome-headless-shell（mac-${CHROME_ARCH}）"
CURL2=$(curl -m 30 -fsSL --retry 6 --retry-all-errors --retry-delay 3 --http1.1 ${PX:+-x "$PX"} https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
  | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);print([x['url'] for x in d['channels']['Stable']['downloads']['chrome-headless-shell'] if x['platform']=='mac-$CHROME_ARCH'][0])")
# chrome-headless-shell ~95MB：优先 npmmirror 镜像（国内直连、免代理、快），失败再 googleapis 经代理；
# 均带 -C - 断点续传 + 下到 .part 再改名（弱网/代理下大文件靠续传兜底，半截文件不会被当成已下好）
CHS_MIRROR=$(printf '%s' "$CURL2" | sed 's#https://storage.googleapis.com/chrome-for-testing-public/#https://cdn.npmmirror.com/binaries/chrome-for-testing/#')
if [ ! -s "$CACHE/chs.zip" ]; then
  curl -C - -m 600 -fsSL --retry 6 --retry-all-errors --retry-delay 3 --http1.1 -o "$CACHE/chs.zip.part" "$CHS_MIRROR" \
    || curl -C - -m 600 -fsSL --retry 6 --retry-all-errors --retry-delay 3 --http1.1 ${PX:+-x "$PX"} -o "$CACHE/chs.zip.part" "$CURL2"
  mv "$CACHE/chs.zip.part" "$CACHE/chs.zip"
fi
rm -rf "$STAGE/chromium"; mkdir -p "$STAGE/chromium"; unzip -oq "$CACHE/chs.zip" -d "$STAGE/chromium"
CHS=$(find "$STAGE/chromium" -name chrome-headless-shell -type f | head -1)
xattr -dr com.apple.quarantine "$STAGE/chromium" 2>/dev/null || true
ok "chrome-headless-shell  arch=$(arch_of "$CHS")"

# ---- 10) 工具/启动器/配置/表单/服务（arch 无关，取自 src/）+ 瘦身 node ----
say "10/12 工具 + 启动器 + 配置"
mkdir -p "$STAGE/tools"; cp "$HERE/src/tools/"*.py "$STAGE/tools/"
( cd "$STAGE/tools"; for t in parsedoc websearch describe-image md2docx md2pdf; do ln -sf "$t.py" "$t"; done ); chmod +x "$STAGE/tools/"*.py
cp "$HERE/src/start-web.sh" "$STAGE/start-web.sh"; chmod +x "$STAGE/start-web.sh"
cp "$HERE/src/CLAUDE.md" "$STAGE/CLAUDE.md"
cp "$HERE/src/com.igemini.web.plist" "$STAGE/com.igemini.web.plist"
rm -rf "$STAGE/runtime/node/include" "$STAGE/runtime/node/lib/node_modules/npm" "$STAGE/runtime/node/lib/node_modules/corepack" \
       "$STAGE/runtime/node/bin/npm" "$STAGE/runtime/node/bin/npx" "$STAGE/runtime/node/bin/corepack" "$STAGE/runtime/node/share" 2>/dev/null || true
ok "工具/启动器就位，node 瘦身"

# ---- 10.5) 法务件（AGPL 合规）----
# claudecodeui(siteboon) 是 AGPL-3.0，我们改了它（白标 patch）→ 分发这个二进制包时，
# 必须随附【许可证全文】+【我们改动的对应源码】+【重建说明】。与 Windows 包的 legal/ 对齐。
# 大陆访问不了 gnu.org / GitHub，所以许可证正文和 patch 都必须【随包带】，不能只给 URL。
say "10.5/12 法务件（AGPL 合规）"
mkdir -p "$STAGE/legal"
cp "$PATCH" "$STAGE/legal/igemini-claudecodeui.patch"
cp "$HERE/resources/LICENSE.txt" "$STAGE/legal/LICENSE-AGPL-3.0.txt"   # 仓库内置的 AGPL-3.0 全文
cat > "$STAGE/legal/SOURCE.txt" <<EOF
iGemini 内含第三方开源组件 claudecodeui（作者 siteboon），许可证 AGPL-3.0。
按 AGPL 要求，随二进制提供对应完整源码的获取方式：

  上游仓库    : https://github.com/${CCUI_REPO}
  基线 commit : ${CCUI_COMMIT}
  白标改动    : 见同目录 igemini-claudecodeui.patch
                （克隆上游后 git checkout ${CCUI_COMMIT}，再 git apply --binary <该 patch>，
                  即可逐字节重建本包内的 claudecodeui）

注：本 macOS 版在出厂构建时另有一处平台特有改动（让会话发现/命名识别 CLAUDE_CONFIG_DIR），
    不在上面这个共享 patch 内。索取完整对应源码请访问项目主页：
      https://github.com/DexterSLamb/iGemini

本目录另含 LICENSE-AGPL-3.0.txt（AGPL-3.0 许可证全文）。
EOF
ok "legal/ 就位（AGPL 全文 + 白标 patch + SOURCE.txt）"

# ---- 11) 组装 pkgroot + pkgbuild（latest 压缩）----
say "11/12 pkgbuild"
rm -rf "$PKGROOT"; mkdir -p "$PKGROOT/Applications/iGemini"
for d in runtime claude-pkg claudecodeui python chromium bin tools legal start-web.sh CLAUDE.md com.igemini.web.plist; do
  cp -R "$STAGE/$d" "$PKGROOT/Applications/iGemini/"
done
cp -R "$STAGE/iGemini.app" "$PKGROOT/Applications/iGemini.app"
pkgbuild --root "$PKGROOT" --install-location / --scripts "$HERE/pkg-scripts" \
  --identifier com.igemini.pkg --version "$VER" --compression latest --min-os-version 12.0 \
  "$OUT/iGemini-component-$ARCH.pkg"
ok "组件包 $(du -h "$OUT/iGemini-component-$ARCH.pkg" | cut -f1)"

# ---- 12) productbuild（界面 + 目标 arch 限定）----
say "12/12 productbuild"
# 原生 RTF 欢迎页：textutil 从 welcome.src.html 转 → 走安装器【原生文本视图】（系统字体，与许可证页一致）
# textutil 默认套 Times(衬线/非 native)，sed 换成系统无衬线 Helvetica Neue 并保留粗体
textutil -convert rtf -inputencoding UTF-8 -output "$HERE/resources/welcome.rtf" "$HERE/resources/welcome.src.html"
sed -i '' -e 's/Times-Bold/Helvetica Neue Bold/g' -e 's/Times-Roman/Helvetica Neue/g' -e 's/\\froman/\\fswiss/g' "$HERE/resources/welcome.rtf"
DIST="$CACHE/distribution.xml"
cat > "$DIST" <<XEOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>iGemini</title>
  <welcome file="welcome.rtf" mime-type="text/rtf"/>
  <license file="LICENSE.txt"/>
  <options customize="never" require-scripts="true" hostArchitectures="$PKG_HOST"/>
  <volume-check><allowed-os-versions><os-version min="12.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default"><pkg-ref id="com.igemini.pkg"/></choice>
  <pkg-ref id="com.igemini.pkg" version="$VER">iGemini-component-$ARCH.pkg</pkg-ref>
</installer-gui-script>
XEOF
# welcome.rtf / LICENSE.txt 由 productbuild --resources 直接引用，无需额外拷贝
PRODUCT="$OUT/iGemini-Installer-$ARCH-v$MKVER.pkg"   # 包名带用户可见版本号
productbuild --distribution "$DIST" --resources "$HERE/resources" --package-path "$OUT" "$PRODUCT"

say "完成"
echo "  产物: $PRODUCT  ($(du -h "$PRODUCT" | cut -f1))  版本=$MKVER  目标=$PKG_HOST"
