#!/usr/bin/env bash
# ============================================================================
# scripts/linux/shell-app/build-appimage.sh — 构建 iGemini 桌面壳 AppImage
#
#   产出单文件 `iGemini-x86_64.AppImage`：双击即用、可放任意路径、自带图标。
#   它是**薄壳**——复用机器上已装的 chromium，以 `--app` 模式开一个无浏览器
#   边框的窗口指向本机 iGemini（localhost:8888），效果同 mac 的 WKWebView 壳 /
#   win 的 WebView2 壳。双击先确保后端 systemd 服务在跑、等端口起来再开窗。
#
#   依赖：构建机要能跑 appimagetool；**目标机双击运行需 libfuse2**
#   （`sudo apt install -y libfuse2`；setup.sh 已纳入）。
#
# 用法（在 Linux 上跑）:
#   PROXY=http://127.0.0.1:7897 bash build-appimage.sh   # 经代理取 appimagetool
#   bash build-appimage.sh                               # 直连
#   产物默认输出到本脚本同目录的 iGemini-x86_64.AppImage（已 gitignore，不入库）。
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
ICON="${ICON:-$REPO_ROOT/assets/igemini-icon.png}"
OUT="${OUT:-$HERE/iGemini-x86_64.AppImage}"
URL="${URL:-http://127.0.0.1:8888}"     # 壳指向的本机地址
PROXY="${PROXY:-}"

[ -f "$ICON" ] || { echo "找不到图标: $ICON"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/iGemini.AppDir"; mkdir -p "$APPDIR"

# ---- AppRun：双击时执行的入口 ----
cat > "$APPDIR/AppRun" <<EOF
#!/bin/bash
# 1) 确保后端服务在跑（systemd 用户服务；开机本应已自启，这里兜底）
systemctl --user start igemini-web 2>/dev/null || true
# 2) 等 8888 起来（最多 ~9s）
for i in \$(seq 1 30); do
  (exec 3<>/dev/tcp/127.0.0.1/8888) 2>/dev/null && { exec 3>&-; break; }
  sleep 0.3
done
# 3) 找 chromium（壳复用系统 chromium）
BIN=""
for b in chromium chromium-browser google-chrome google-chrome-stable; do
  command -v "\$b" >/dev/null 2>&1 && { BIN="\$b"; break; }
done
if [ -z "\$BIN" ]; then
  command -v zenity >/dev/null 2>&1 && zenity --error --text="未找到 chromium，无法打开 iGemini"
  echo "未找到 chromium" >&2; exit 1
fi
# 4) 无边框 app 窗口（独立 profile，不串用户日常 chromium）
exec "\$BIN" --app="$URL" --class=iGemini --name=iGemini \\
  --user-data-dir="\$HOME/.config/igemini-shell" \\
  --no-first-run --no-default-browser-check "\$@"
EOF
chmod +x "$APPDIR/AppRun"

# ---- .desktop（AppImage 元数据：名字 + 图标）----
cat > "$APPDIR/iGemini.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=iGemini
Comment=iGemini 网页壳（Claude Code + DeepSeek 后端）
Exec=AppRun
Icon=igemini
Categories=Network;Development;Utility;
Terminal=false
EOF

# ---- 图标（名字须与 Icon=igemini 对应）----
cp "$ICON" "$APPDIR/igemini.png"

# ---- appimagetool（自身用 --extract-and-run 免 FUSE）----
TOOL="${APPIMAGETOOL:-/tmp/appimagetool}"
if [ ! -x "$TOOL" ]; then
  echo "取 appimagetool ..."
  curl -fsSL ${PROXY:+-x "$PROXY"} -o "$TOOL" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$TOOL"
fi

echo "打包 AppImage ..."
ARCH=x86_64 "$TOOL" --appimage-extract-and-run "$APPDIR" "$OUT"
chmod +x "$OUT"
echo "✓ 已生成: $OUT  ($(stat -c%s "$OUT" 2>/dev/null || echo '?') 字节)"
echo "  双击运行需 libfuse2：sudo apt install -y libfuse2"
echo "  放任意路径双击即可（首次可能需右键→属性→允许执行）。"
