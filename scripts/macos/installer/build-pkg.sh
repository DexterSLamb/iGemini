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
#   外网二进制（github/codeload/googleapis/python-build-standalone）可经显式 PROXY；
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
CLAUDE_CODE_VERSION="$(tr -d '\r\n' < "$REPO/scripts/common/CLAUDE_CODE_VERSION")"
CLAUDE_VERIFIER="$REPO/scripts/common/verify-claude-code.mjs"
CLAUDE_SANITIZER="$REPO/scripts/common/sanitize-claude-state.mjs"
PRODUCT_IDENTITY_PATCH="$REPO/scripts/common/patch-cloudcli-product-identity.py"
PRODUCT_SYSTEM_PROMPT="$REPO/scripts/common/igemini-system-prompt.md"
SHELL_IDENTITY_PATCH="$REPO/scripts/common/patch-cloudcli-shell-identity.py"
SINGLE_PROVIDER_PATCH="$REPO/scripts/common/patch-cloudcli-single-provider.py"
RUNTIME_PRUNER="$REPO/scripts/common/prune-cloudcli-runtime.mjs"
PYTHON_RUNTIME_PRUNER="$REPO/scripts/common/prune-python-runtime.py"
RUNTIME_INSTALL_PRUNER="$HERE/src/prune-installed-runtime.py"
MACOS_IME_PATCH="$HERE/src/patch-cloudcli-macos-ime.py"
MACOS_CLIPBOARD_PATCH="$HERE/src/patch-cloudcli-macos-clipboard.py"
# 构建工作目录放无空格路径（node-gyp 源码编译遇路径空格会失败；本仓在 "Claude Code/" 下有空格）
WORK="${IGBUILD_WORK:-/tmp/igbuild}/$ARCH"
CACHE="$WORK/cache"; STAGE="$WORK/staging"; PKGROOT="$WORK/pkgroot"; OUT="$HERE/out"
PX="${PROXY:-}"
PATCH="$REPO/vendor/igemini-claudecodeui.patch"
ICON="$REPO/assets/igemini-icon.png"
ICON_COMPOSER_JSON="$REPO/scripts/macos/cloudcli-webkit/AppIcon.icon.json"
CCUI_REPO="siteboon/claudecodeui"
CCUI_COMMIT="27eaf0146a46aa8a55178f3d394360ff7465420f"
NODE_CDN="https://cdn.npmmirror.com/binaries/node"
NPM_MIRROR="https://registry.npmmirror.com"
PIP_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok(){  printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
die(){ printf '  \033[0;31m✗ %s\033[0m\n' "$*"; exit 1; }
arch_of(){ file "$1" 2>/dev/null | grep -oE 'arm64|x86_64' | head -1; }
# 从 GitHub 下载：显式提供 PROXY 时优先走代理；否则走系统网络，
# 最后尝试公共镜像。下载只写 .part，完成后原子改名。
GHMIRRORS=( "https://ghfast.top/" "https://gh-proxy.com/" "https://github.moeyy.xyz/" "https://ghproxy.net/" )
dlgh(){  # $1=github完整URL  $2=目标文件
  local url="$1" dest="$2" part="${2}.part" m
  if [ -n "$PX" ]; then
    curl --connect-timeout 30 -m 1800 -fsSL -C - --retry 2 --retry-all-errors --retry-delay 2 \
      --http1.1 -x "$PX" -o "$part" "$url" 2>/dev/null \
      && [ -s "$part" ] && { mv "$part" "$dest"; echo "    (via 代理直连)"; return 0; }
  fi
  if curl --connect-timeout 20 -m 1800 -fsSL -C - --retry 2 --retry-all-errors --retry-delay 2 \
      --http1.1 -o "$part" "$url" 2>/dev/null \
      && [ -s "$part" ]; then
    mv "$part" "$dest"; echo "    (via 系统网络)"; return 0
  fi
  rm -f "$part"
  for m in "${GHMIRRORS[@]}"; do
    curl --connect-timeout 20 -m 600 -fsSL --retry 1 --retry-all-errors --retry-delay 2 \
      --http1.1 -o "$part" "${m}${url}" 2>/dev/null \
      && [ -s "$part" ] && { mv "$part" "$dest"; printf '    (via %s)\n' "$m"; return 0; }
    rm -f "$part"
  done
  return 1
}
valid_zip(){ unzip -tq "$1" >/dev/null 2>&1; }
valid_tgz(){ tar -tzf "$1" >/dev/null 2>&1; }
# 固定版本（避开 api.github.com 调用；可按需更新）
PANDOC_VER="3.10"; PY_TAG="20260623"; PY_VER="3.12.13"
MKVER="$(tr -d ' \t\r\n' < "$HERE/VERSION" 2>/dev/null)"; [ -n "$MKVER" ] || MKVER="1.0.0"   # 用户可见版本(单一真源: installer/VERSION)——贯穿 关于面板 / Info.plist / 包名
VER="$MKVER.$(date +%Y%m%d%H%M%S)"   # pkg 内部版本 = 营销版本.秒级时间戳 → 每次构建递增、绝不撞版本；安装器把每次安装都当新版本完整铺 payload（避免同版本重装跳过文件）

[ -f "$PATCH" ] || die "缺白标 patch: $PATCH"
[ -f "$CLAUDE_VERIFIER" ] || die "缺 Claude 完整性校验器: $CLAUDE_VERIFIER"
[ -f "$CLAUDE_SANITIZER" ] || die "缺 Claude 状态清理器: $CLAUDE_SANITIZER"
[ -f "$PRODUCT_IDENTITY_PATCH" ] || die "缺产品身份注入补丁: $PRODUCT_IDENTITY_PATCH"
[ -s "$PRODUCT_SYSTEM_PROMPT" ] || die "缺 iGemini 产品身份 prompt: $PRODUCT_SYSTEM_PROMPT"
[ -f "$SHELL_IDENTITY_PATCH" ] || die "缺 Shell 身份注入补丁: $SHELL_IDENTITY_PATCH"
[ -f "$SINGLE_PROVIDER_PATCH" ] || die "缺单助手产品补丁: $SINGLE_PROVIDER_PATCH"
[ -f "$RUNTIME_PRUNER" ] || die "缺 CloudCLI 运行时裁剪器: $RUNTIME_PRUNER"
[ -f "$PYTHON_RUNTIME_PRUNER" ] || die "缺 Python 运行时裁剪器: $PYTHON_RUNTIME_PRUNER"
[ -f "$RUNTIME_INSTALL_PRUNER" ] || die "缺安装后运行时清理器: $RUNTIME_INSTALL_PRUNER"
[ -f "$MACOS_IME_PATCH" ] || die "缺 macOS Shell 中文输入补丁: $MACOS_IME_PATCH"
[ -f "$MACOS_CLIPBOARD_PATCH" ] || die "缺 macOS Shell 原生剪贴板补丁: $MACOS_CLIPBOARD_PATCH"
[ -s "$ICON" ] || die "缺 iGemini 图标源文件: $ICON"
[ -s "$ICON_COMPOSER_JSON" ] || die "缺 Icon Composer 配置: $ICON_COMPOSER_JSON"
command -v xcrun >/dev/null || die "缺 Xcode CLT(clang)"
xcrun --find actool >/dev/null 2>&1 || die "缺 Xcode 26 actool（macOS 26 分层图标构建需要完整 Xcode）"
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
env "${NPMENV[@]}" npm install --prefix "$STAGE/claude-pkg" --cpu "$NODE_ARCH" --os darwin "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" >/dev/null
CLBIN=$(find "$STAGE/claude-pkg/node_modules/@anthropic-ai" -path "*darwin-$NODE_ARCH*/claude" -type f | head -1)
[ -n "$CLBIN" ] || die "没装到 claude-code-darwin-$NODE_ARCH 二进制"
CLAUDE_VERIFY_ARGS=(
  --package-root "$STAGE/claude-pkg/node_modules/@anthropic-ai/claude-code"
  --binary "$CLBIN" --platform "darwin-$NODE_ARCH"
  --require-binary-sha256
)
node "$CLAUDE_VERIFIER" "${CLAUDE_VERIFY_ARGS[@]}" || die "Claude Code 固定版本/哈希校验失败"
CLAUDE_GENERIC_BIN="$STAGE/claude-pkg/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
[ -e "$CLAUDE_GENERIC_BIN" ] || die "Claude npm 通用包缺少预期入口"
CLAUDE_GENERIC_SIZE=$(stat -f '%z' "$CLAUDE_GENERIC_BIN" 2>/dev/null || echo 0)
rm -f "$CLAUDE_GENERIC_BIN" \
      "$STAGE/claude-pkg/node_modules/.bin/claude"
rmdir "$STAGE/claude-pkg/node_modules/@anthropic-ai/claude-code/bin" \
      "$STAGE/claude-pkg/node_modules/.bin" 2>/dev/null || true
[ ! -e "$STAGE/claude-pkg/node_modules/@anthropic-ai/claude-code/bin/claude.exe" ] \
  || die "Claude 重复二进制删除失败"
ok "claude $CLAUDE_CODE_VERSION 二进制 arch=$(arch_of "$CLBIN")（已按审计清单校验；移除未采用通用入口 ${CLAUDE_GENERIC_SIZE}B）"

# 这里只缓存步骤 3-5 的 CloudCLI 源码/前端/服务端构建；必须覆盖这些步骤的全部输入。
# VERSION 会进入 VITE_IGEMINI_VERSION，单独变更版本号时也必须使缓存失效。
BUILD_FINGERPRINT="$(shasum -a 256 "$PATCH" "$REPO/scripts/common/patch-cloudcli-claude-config.py" \
  "$PRODUCT_IDENTITY_PATCH" "$PRODUCT_SYSTEM_PROMPT" "$SHELL_IDENTITY_PATCH" "$SINGLE_PROVIDER_PATCH" \
  "$RUNTIME_PRUNER" "$RUNTIME_INSTALL_PRUNER" "$MACOS_IME_PATCH" "$MACOS_CLIPBOARD_PATCH" \
  "$HERE/VERSION" "$HERE/build-pkg.sh" | shasum -a 256 | awk '{print $1}')"
if [ -d "$STAGE/claudecodeui/dist-server" ] \
   && [ "$(cat "$STAGE/claudecodeui/.igemini-build-fingerprint" 2>/dev/null || true)" = "$BUILD_FINGERPRINT" ]; then
  ok "claudecodeui 构建指纹匹配，复用（跳过 3-5）"
else
# ---- 3) claudecodeui 源码（codeload tarball 经代理 + 套白标 patch）----
say "3/12 claudecodeui 源码 + 白标 patch"
TGZ="$CACHE/ccui.tgz"
[ -f "$TGZ" ] && ! valid_tgz "$TGZ" && rm -f "$TGZ"
[ -f "$TGZ" ] || dlgh "https://github.com/$CCUI_REPO/archive/$CCUI_COMMIT.tar.gz" "$TGZ" || die "claudecodeui 源码下载失败（镜像+代理都不通）"
tar -tzf "$TGZ" 2>/dev/null | grep -q package.json || die "claudecodeui 压缩包无效"
rm -rf "$STAGE/claudecodeui"; mkdir -p "$STAGE/claudecodeui"
tar -xzf "$TGZ" -C "$STAGE/claudecodeui" --strip-components=1
( cd "$STAGE/claudecodeui" && git init -q && git apply --binary "$PATCH" )
# iGemini 隔离补丁（不进共享白标 patch）：让 CloudCLI 所有直接读取的 Claude
# session/auth/skills/MCP/agent 路径都跟随 CLAUDE_CONFIG_DIR。
python3 "$REPO/scripts/common/patch-cloudcli-claude-config.py" "$STAGE/claudecodeui"
python3 "$PRODUCT_IDENTITY_PATCH" "$STAGE/claudecodeui"
python3 "$SHELL_IDENTITY_PATCH" "$STAGE/claudecodeui"
python3 "$SINGLE_PROVIDER_PATCH" "$STAGE/claudecodeui"
python3 "$MACOS_IME_PATCH" "$STAGE/claudecodeui"
python3 "$MACOS_CLIPBOARD_PATCH" "$STAGE/claudecodeui"
ok "已套白标 + CLAUDE_CONFIG_DIR + 原生产品身份 + iGemini 单助手 + macOS Shell 中文输入/原生剪贴板补丁"

# ---- 4) npm ci（按构建机 arch 装；保证 build 工具 rollup/vite/esbuild 可在构建机上跑）----
say "4/12 npm ci"
( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm ci >/dev/null )
ok "依赖装好（构建机 arch；运行时原生模块稍后重建为目标 arch）"

# ---- 5) build（构建机 arch 工具）+ 运行时原生重建为目标 arch + bypass + 标题 + prune ----
say "5/12 build + 原生重建(${NODE_ARCH}) + 补丁 + prune"
( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    VITE_IGEMINI_VERSION="$MKVER" npm run build >/dev/null )
if [ "$NODE_ARCH" != "arm64" ]; then   # 构建机=arm64；目标非 arm64 → 把运行时原生模块(node-pty/better-sqlite3/bcrypt 等)重建为目标 arch
  ( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" \
      npm_config_arch="$NODE_ARCH" npm_config_target_arch="$NODE_ARCH" npm_config_nodedir="$STAGE/runtime/node" \
      npm rebuild >/dev/null )
  SQL=$(find "$STAGE/claudecodeui/node_modules/better-sqlite3" -name "*.node" 2>/dev/null | head -1)
  BCR=$(find "$STAGE/claudecodeui/node_modules/bcrypt" -name "*.node" 2>/dev/null | head -1)
  ok "运行时原生重建 → better-sqlite3:$(arch_of "$SQL")  bcrypt:$(arch_of "$BCR")"
fi
# @vscode/ripgrep 的 npm postinstall 已为构建机安装 host-arch bin。若它正好
# 等于目标架构就直接复用；仅交叉构建时强制重取，避免无意义的网络依赖。
# 代理变量同时覆盖大小写（proxy-from-env）并在外层重试，抵御 GitHub 抖动。
RG_ROOT="$STAGE/claudecodeui/node_modules/@vscode/ripgrep"
RG_BIN="$RG_ROOT/bin/rg"
RG_EXPECTED_ARCH="$CLANG_ARCH"
RG_VERSION="$(node -p "require('$RG_ROOT/package.json').version")"
RG_CACHE="$CACHE/ripgrep-$RG_VERSION-$NODE_ARCH"
if [ "$(arch_of "$RG_BIN")" != "$RG_EXPECTED_ARCH" ]; then
  if [ -x "$RG_CACHE" ] && [ "$(arch_of "$RG_CACHE")" = "$RG_EXPECTED_ARCH" ]; then
    /bin/cp "$RG_CACHE" "$RG_BIN"
  else
    RG_READY=0
    for RG_ATTEMPT in 1 2 3; do
      if ( cd "$RG_ROOT" && env \
          npm_config_arch="$NODE_ARCH" \
          HTTPS_PROXY="$PX" HTTP_PROXY="$PX" https_proxy="$PX" http_proxy="$PX" \
          npm_config_https_proxy="$PX" npm_config_proxy="$PX" \
          node lib/postinstall.js --force >/dev/null ); then
        RG_READY=1
        break
      fi
      [ "$RG_ATTEMPT" -lt 3 ] && sleep $((RG_ATTEMPT * 2))
    done
    [ "$RG_READY" -eq 1 ] || die "ripgrep ${NODE_ARCH} 下载失败（已重试 3 次）"
  fi
fi
[ "$(arch_of "$RG_BIN")" = "$RG_EXPECTED_ARCH" ] \
  || die "ripgrep 架构不匹配：期望 ${RG_EXPECTED_ARCH}，实际 $(arch_of "$RG_BIN")"
/bin/cp "$RG_BIN" "$RG_CACHE.part"
/bin/chmod 755 "$RG_CACHE.part"
/bin/mv "$RG_CACHE.part" "$RG_CACHE"
ok "ripgrep 目标架构校验通过 → $(arch_of "$RG_BIN")"
python3 - "$STAGE/claudecodeui/dist-server/server/claude-sdk.js" <<'PY'
import sys; f=sys.argv[1]; s=open(f,encoding="utf-8").read()
old="if (settings.skipPermissions && permissionMode !== 'plan') {"
new="if (permissionMode !== 'plan') { // [iGemini] always bypass permissions (macOS)"
if "[iGemini] always bypass" not in s and old in s:
    open(f,"w",encoding="utf-8").write(s.replace(old,new))
PY
grep -Fq "[iGemini] Claude shell identity + bypass" \
  "$STAGE/claudecodeui/dist-server/server/modules/websocket/services/shell-websocket.service.js" \
  || die "Shell 原生身份/免权限补丁未进入编译产物"
# JWT 有效期 7d → 3650d：壳只在启动时自动登录一次、不续签，7 天后 token 过期 → 聊天 WS 鉴权失败。
# 本机 / 固定账号 iGemini/iGemini 场景下长效 token 无实际危害；将来做远程鉴权改造时再收回。
python3 - "$STAGE/claudecodeui/dist-server/server/middleware/auth.js" <<'PY'
import sys; f=sys.argv[1]; s=open(f,encoding="utf-8").read()
if "expiresIn: '3650d'" not in s and "expiresIn: '7d'" in s:
    open(f,"w",encoding="utf-8").write(s.replace("expiresIn: '7d'","expiresIn: '3650d'")); print("JWT 有效期 7d → 3650d")
PY
sed -i '' 's|<title>CloudCLI UI</title>|<title>iGemini</title>|' "$STAGE/claudecodeui/dist/index.html" "$STAGE/claudecodeui/index.html" 2>/dev/null || true
( cd "$STAGE/claudecodeui" && env "${NPMENV[@]}" npm prune --omit=dev >/dev/null 2>&1 || true )
node "$RUNTIME_PRUNER" --root "$STAGE/claudecodeui" --platform darwin --arch "$NODE_ARCH" \
  --runtime-node "$STAGE/runtime/node/bin/node" >/dev/null
printf '%s\n' "$BUILD_FINGERPRINT" > "$STAGE/claudecodeui/.igemini-build-fingerprint"
ok "dist + dist-server 就绪；单助手模式 + 目标架构运行时白名单已验证"
fi

# ---- 6) pandoc（目标 arch）----
say "6/12 pandoc $PANDOC_VER"
[ -f "$CACHE/pandoc.zip" ] && ! valid_zip "$CACHE/pandoc.zip" && rm -f "$CACHE/pandoc.zip"
[ -f "$CACHE/pandoc.zip" ] || dlgh "https://github.com/jgm/pandoc/releases/download/$PANDOC_VER/pandoc-$PANDOC_VER-$PANDOC_ARCH-macOS.zip" "$CACHE/pandoc.zip" || die "pandoc 下载失败（镜像+代理都不通）"
rm -rf "$CACHE/pdx"; mkdir -p "$CACHE/pdx" "$STAGE/bin"; unzip -oq "$CACHE/pandoc.zip" -d "$CACHE/pdx"
cp "$(find "$CACHE/pdx" -name pandoc -type f -perm +111 | head -1)" "$STAGE/bin/pandoc"; chmod +x "$STAGE/bin/pandoc"
ok "pandoc $PANDOC_VER  arch=$(arch_of "$STAGE/bin/pandoc")"

# ---- 7) python-build-standalone（目标 arch）+ pip 依赖 ----
say "7/12 python $PY_VER + 五大能力依赖"
[ -f "$CACHE/python.tgz" ] && ! valid_tgz "$CACHE/python.tgz" && rm -f "$CACHE/python.tgz"
[ -f "$CACHE/python.tgz" ] || dlgh "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG/cpython-$PY_VER+$PY_TAG-$PY_ARCH-apple-darwin-install_only.tar.gz" "$CACHE/python.tgz" || die "python 下载失败（镜像+代理都不通）"
rm -rf "$STAGE/python"; mkdir -p "$STAGE/python"; tar -xzf "$CACHE/python.tgz" -C "$STAGE/python" --strip-components=1
"$STAGE/python/bin/python3" -m pip install --no-warn-script-location --disable-pip-version-check --only-binary=:all: -i "$PIP_MIRROR" \
  PyMuPDF pdfplumber python-docx openpyxl markdown pandas >/dev/null
"$STAGE/python/bin/python3" -c "import fitz,pdfplumber,docx,openpyxl,markdown,pandas" || die "python 依赖 import 失败"
"$STAGE/python/bin/python3" -B "$PYTHON_RUNTIME_PRUNER" --root "$STAGE/python" --platform darwin --arch "$NODE_ARCH" \
  || die "python 运行时裁剪失败"
"$STAGE/python/bin/python3" -B -c "import fitz,pdfplumber,docx,openpyxl,markdown,pandas" \
  || die "python 裁剪后依赖 import 失败"
"$STAGE/python/bin/python3" -B -c "import fitz,io,pdfplumber;d=fitz.open();p=d.new_page();p.insert_text((72,72),'iGemini runtime probe');b=d.tobytes();d.close();q=pdfplumber.open(io.BytesIO(b));assert len(q.pages)==1 and 'iGemini' in (q.pages[0].extract_text() or '');q.close();print('python-runtime-probe=ok')" \
  || die "python 裁剪后 PDF 读写能力测试失败"
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
# macOS 26 用 Icon Composer 的分层 Assets.car，让系统原生生成 Liquid Glass
# 圆角方形且不再给透明圆形图补白底。旧系统仍由 Info.plist 的 icon.icns
# 提供既有圆形图；postinstall 仅在 macOS 26+ 添加 CFBundleIconName=AppIcon。
ICON_DOCUMENT="$CACHE/AppIcon.icon"
ICON_OUTPUT="$CACHE/iGemini-AppIcon-assets"
ICON_PARTIAL_PLIST="$CACHE/iGemini-AppIcon-partial.plist"
ICON_ASSET_INFO="$CACHE/iGemini-AppIcon-assets.json"
ICON_COMPOSER_SOURCE="$CACHE/iGemini-AppIcon-source.png"
rm -rf "$ICON_DOCUMENT" "$ICON_OUTPUT"
mkdir -p "$ICON_DOCUMENT/Assets" "$ICON_OUTPUT"
cp "$ICON_COMPOSER_JSON" "$ICON_DOCUMENT/icon.json"
# 共享品牌 PNG 是旧系统圆形图源，外围包含 87 px 透明留白和约 45–50 px
# 白色圆环。Icon Composer 会在其外再生成 macOS 26 圆角容器，若直接使用就
# 形成双层边缘。仅为 macOS 26 居中裁取 1220×1220 的圆环内侧并恢复到
# 1500×1500；原始图和 macOS 12–15 的 icon.icns 均保持不变。
cp "$ICON" "$ICON_COMPOSER_SOURCE"
sips -c 1220 1220 "$ICON_COMPOSER_SOURCE" >/dev/null
sips -z 1500 1500 "$ICON_COMPOSER_SOURCE" >/dev/null
cp "$ICON_COMPOSER_SOURCE" "$ICON_DOCUMENT/Assets/iGemini.png"
xcrun actool --compile "$ICON_OUTPUT" \
  --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --target-device mac --standalone-icon-behavior none \
  --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
  --warnings --errors --notices --output-format human-readable-text \
  "$ICON_DOCUMENT" >/dev/null
[ -s "$ICON_OUTPUT/Assets.car" ] || die "Icon Composer 未生成 Assets.car"
xcrun assetutil --info "$ICON_OUTPUT/Assets.car" > "$ICON_ASSET_INFO"
grep -Fq '"AssetType" : "IconImageStack"' "$ICON_ASSET_INFO" \
  || die "Assets.car 缺少 macOS 26 分层图标"
cp "$ICON_OUTPUT/Assets.car" "$APP/Contents/Resources/Assets.car"
for L in en zh-Hans; do [ -d "$WSRC/$L.lproj" ] && cp -R "$WSRC/$L.lproj" "$APP/Contents/Resources/"; done
xattr -cr "$APP"; codesign --force --deep -s - "$APP" 2>/dev/null
ok "壳 arch=$(arch_of "$APP/Contents/MacOS/iGemini")  旧版圆形 icns + macOS 26 分层图标均已验证；已 ad-hoc 签名"

# ---- 9) chrome-headless-shell（目标 arch；md2pdf 用）----
say "9/12 chrome-headless-shell（mac-${CHROME_ARCH}）"
CURL2=$(curl -m 30 -fsSL --retry 6 --retry-all-errors --retry-delay 3 --http1.1 ${PX:+-x "$PX"} https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
  | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);print([x['url'] for x in d['channels']['Stable']['downloads']['chrome-headless-shell'] if x['platform']=='mac-$CHROME_ARCH'][0])")
[ -f "$CACHE/chs.zip" ] && ! valid_zip "$CACHE/chs.zip" && rm -f "$CACHE/chs.zip"
if [ ! -f "$CACHE/chs.zip" ]; then
  # 显式提供 PROXY 时优先走代理；当前网络直连可能不报错但只有几十 KiB/s。
  if [ -n "$PX" ]; then
    curl --connect-timeout 30 -m 1800 -fsSL -C - --retry 6 --retry-all-errors --retry-delay 3 \
      --http1.1 -x "$PX" -o "$CACHE/chs.zip.part" "$CURL2"
  else
    curl --connect-timeout 30 -m 1800 -fsSL -C - --retry 6 --retry-all-errors --retry-delay 3 \
      --http1.1 -o "$CACHE/chs.zip.part" "$CURL2"
  fi
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
cp "$CLAUDE_SANITIZER" "$STAGE/sanitize-claude-state.mjs"; chmod +x "$STAGE/sanitize-claude-state.mjs"
cp "$RUNTIME_INSTALL_PRUNER" "$STAGE/prune-installed-runtime.py"; chmod +x "$STAGE/prune-installed-runtime.py"
cp "$PRODUCT_SYSTEM_PROMPT" "$STAGE/igemini-system-prompt.md"
cp "$HERE/src/CLAUDE.md" "$STAGE/CLAUDE.md"
cp "$HERE/src/com.igemini.web.plist" "$STAGE/com.igemini.web.plist"
rm -rf "$STAGE/runtime/node/include" "$STAGE/runtime/node/lib/node_modules/corepack" \
       "$STAGE/runtime/node/bin/corepack" "$STAGE/runtime/node/share" \
       "$STAGE/runtime/node/CHANGELOG.md" "$STAGE/runtime/node/README.md" 2>/dev/null || true
"$STAGE/runtime/node/bin/npm" --version >/dev/null || die "node 裁剪后 npm 冒烟测试失败"
"$STAGE/runtime/node/bin/npx" --version >/dev/null || die "node 裁剪后 npx 冒烟测试失败"
ok "工具/启动器就位，node 瘦身（保留插件与 TaskMaster 所需 npm/npx）"

# ---- 10.5) 法务件（AGPL 合规）----
# claudecodeui(siteboon) 是 AGPL-3.0，我们改了它（白标 patch）→ 分发这个二进制包时，
# 必须随附【许可证全文】+【对应源码获取方式】+【重建说明】。与 Windows 包的 legal/ 对齐。
# 许可证正文和共享白标 patch 随包携带；修改/构建源码固定到 release tag，完整对应源码包同版发布。
say "10.5/12 法务件（AGPL 合规）"
mkdir -p "$STAGE/legal"
cp "$PATCH" "$STAGE/legal/igemini-claudecodeui.patch"
cp "$HERE/resources/LICENSE.txt" "$STAGE/legal/LICENSE-AGPL-3.0.txt"   # 仓库内置的 AGPL-3.0 全文
cat > "$STAGE/legal/SOURCE.txt" <<EOF
iGemini 内含第三方开源组件 claudecodeui（作者 siteboon），许可证 AGPL-3.0。
按 AGPL 要求，随二进制提供修改源码、构建方式和完整对应源码包的获取方式：

  上游仓库    : https://github.com/$CCUI_REPO
  基线 commit : ${CCUI_COMMIT}
  共享白标改动: 见同目录 igemini-claudecodeui.patch
                 （克隆上游、checkout ${CCUI_COMMIT} 后用 git apply --binary 应用）
  iGemini 修改与构建源码: https://github.com/DexterSLamb/iGemini/tree/v${MKVER}
  完整对应源码包         : 同一 GitHub Release 中的
                           iGemini-Corresponding-Source-v${MKVER}.tar.gz

共享 patch 只重建三平台共用的白标源码改动。对应源码包包含应用全部源码补丁后的
完整 CloudCLI 源码树，以及上述 release tag 的 iGemini 修改与构建源码。运行其中
scripts/macos/installer/build-pkg.sh 会应用剩余的构建期改动并组装本安装包。

本目录另含 LICENSE-AGPL-3.0.txt（AGPL-3.0 许可证全文）。
EOF
ok "legal/ 就位（AGPL 全文 + 白标 patch + SOURCE.txt）"

# ---- 11) 组装 pkgroot + pkgbuild（latest 压缩）----
say "11/12 pkgbuild"
rm -rf "$PKGROOT"; mkdir -p "$PKGROOT/Applications/iGemini"
for d in runtime claude-pkg claudecodeui python chromium bin tools legal start-web.sh sanitize-claude-state.mjs prune-installed-runtime.py igemini-system-prompt.md CLAUDE.md com.igemini.web.plist; do
  cp -R "$STAGE/$d" "$PKGROOT/Applications/iGemini/"
done
RUNTIME_MANIFEST_TMP="$CACHE/runtime-manifest-$ARCH.json"
python3 "$RUNTIME_INSTALL_PRUNER" --write-manifest \
  "$PKGROOT/Applications/iGemini" "$RUNTIME_MANIFEST_TMP" >/dev/null
cp "$RUNTIME_MANIFEST_TMP" "$PKGROOT/Applications/iGemini/.igemini-runtime-manifest.json"
cp -R "$STAGE/iGemini.app" "$PKGROOT/Applications/iGemini.app"
# pkgbuild 默认把 .app 标成可重定位。若构建机/用户磁盘上曾注册过同 Bundle ID
# 的开发壳，Installer 会把 payload 悄悄铺回旧路径，而不是 /Applications。
# 显式关闭重定位与 bundle 版本跳过，确保升级/重装总在产品固定位置原子覆盖。
COMPONENT_PLIST="$CACHE/component-$ARCH.plist"
pkgbuild --analyze --root "$PKGROOT" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" \
  -c "Set :0:BundleIsVersionChecked false" "$COMPONENT_PLIST"
[ "$(plutil -extract 0.BundleIsRelocatable raw "$COMPONENT_PLIST")" = "false" ] \
  || die "iGemini.app 禁止重定位元数据生成失败"
pkgbuild --root "$PKGROOT" --install-location / --scripts "$HERE/pkg-scripts" \
  --component-plist "$COMPONENT_PLIST" \
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

# 只展开 xar 元数据（不解压大 payload）做发布门禁：目标架构、产品 Bundle ID、
# 固定安装路径和禁止重定位必须同时成立，避免 ARM64/x64 再出现行为分叉。
VERIFY="$WORK/package-verify"
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
pkgutil --expand "$PRODUCT" "$VERIFY/product"
COMPONENT_META="$VERIFY/product/iGemini-component-$ARCH.pkg"
[ -d "$COMPONENT_META" ] || die "产品包缺少组件元数据目录: iGemini-component-$ARCH.pkg"
grep -Fq "hostArchitectures=\"$PKG_HOST\"" "$VERIFY/product/Distribution" \
  || die "产品包 hostArchitectures 不匹配: $PKG_HOST"
grep -Fq 'id="uk.igemini.app"' "$COMPONENT_META/PackageInfo" \
  || die "产品包缺少 iGemini 自有 Bundle ID"
# pkgbuild 对不可重定位组件仍会生成空的 <relocate/> 容器；真正的风险是其中
# 存在 bundle 子节点，它会让 Installer 按 LaunchServices 记录迁移 App。
RELOCATE_BUNDLES="$(xmllint --xpath 'count(/pkg-info/relocate/bundle)' \
  "$COMPONENT_META/PackageInfo" 2>/dev/null)"
[ "$RELOCATE_BUNDLES" = "0" ] \
  || die "产品包仍允许 iGemini.app 重定位（bundle 数=$RELOCATE_BUNDLES）"
grep -Fq 'path="./Applications/iGemini.app"' "$COMPONENT_META/PackageInfo" \
  || die "产品包缺少固定 /Applications/iGemini.app payload"
rm -rf "$VERIFY"

say "完成"
echo "  产物: $PRODUCT  ($(du -h "$PRODUCT" | cut -f1))  版本=$MKVER  目标=$PKG_HOST"
