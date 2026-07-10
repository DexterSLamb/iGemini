#!/usr/bin/env python3
# md2pdf <input.md> [output.pdf] — Markdown → 高保真 PDF（python markdown + 无头 chrome-headless-shell，macOS 版）。
# 依赖：markdown(自带 python) + 打包的 chrome-headless-shell。浏览器路径取 $IGEMINI_CHROME，兜底系统 Chrome。
import sys, os, tempfile, subprocess, shutil

if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
    sys.stderr.write("用法: md2pdf <input.md> [output.pdf]\n"); sys.exit(1)
src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else (src[:-3] if src.lower().endswith(".md") else src) + ".pdf"

import markdown
CSS = """
@page { size: A4; margin: 18mm 16mm; }
* { box-sizing: border-box; }
body { font-family:"PingFang SC","Helvetica Neue","Microsoft YaHei","Hiragino Sans GB",system-ui,sans-serif; font-size:11pt; line-height:1.75; color:#24292f; }
h1 { font-size:22pt; margin:0 0 .4em; padding-bottom:.25em; border-bottom:2px solid #d0d7de; }
h2 { font-size:16pt; margin:1.2em 0 .5em; padding-bottom:.2em; border-bottom:1px solid #e6e8eb; }
h3 { font-size:13pt; margin:1em 0 .4em; }
a { color:#0969da; text-decoration:none; word-break:break-all; }
code { font-family:"SF Mono",Menlo,Consolas,monospace; font-size:90%; background:#f6f8fa; padding:.15em .35em; border-radius:4px; }
pre { background:#f6f8fa; padding:12px 14px; border-radius:6px; overflow-x:auto; } pre code { background:none; padding:0; }
table { border-collapse:collapse; width:100%; margin:.8em 0; font-size:10.5pt; }
th,td { border:1px solid #d0d7de; padding:6px 10px; text-align:left; vertical-align:top; }
thead th { background:#f2f4f6; font-weight:600; } tbody tr:nth-child(even) { background:#fafbfc; }
hr { border:none; border-top:1px solid #e6e8eb; margin:1.4em 0; }
blockquote { margin:.8em 0; padding:.2em 1em; color:#57606a; border-left:4px solid #d0d7de; }
"""
body = markdown.markdown(open(src, encoding="utf-8").read(), extensions=["extra", "sane_lists", "toc"])
html = tempfile.mktemp(suffix=".html")
open(html, "w", encoding="utf-8").write(
    "<!doctype html><html lang='zh'><head><meta charset='utf-8'><style>" + CSS + "</style></head><body>" + body + "</body></html>")

# chrome-headless-shell：$IGEMINI_CHROME 优先 → PATH → 系统 Chrome/Edge
cands = [os.environ.get("IGEMINI_CHROME", ""),
         shutil.which("chrome-headless-shell") or "",
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
         "/Applications/Chromium.app/Contents/MacOS/Chromium"]
browser = next((c for c in cands if c and os.path.isfile(c)), None)
if not browser:
    sys.stderr.write("[md2pdf] 找不到 chrome-headless-shell / Chrome\n"); sys.exit(1)

prof = tempfile.mkdtemp()
url = "file://" + os.path.abspath(html)
# chrome-headless-shell 恒为无头，不传 --headless；普通 Chrome 也兼容这些 flag
try:
    subprocess.run([browser, "--disable-gpu", "--no-pdf-header-footer",
        "--user-data-dir=" + prof, "--virtual-time-budget=6000", "--print-to-pdf=" + out, url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
finally:
    try: os.remove(html)
    except OSError: pass
    shutil.rmtree(prof, ignore_errors=True)

if os.path.isfile(out):
    print("已生成 PDF: " + out)
else:
    sys.stderr.write("[md2pdf] 生成失败\n"); sys.exit(1)
