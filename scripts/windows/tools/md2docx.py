#!/usr/bin/env python3
# md2docx <input.md> [output.docx] — Markdown → Word（pandoc，Windows 版）。
import sys, os, subprocess

if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
    sys.stderr.write("用法: md2docx <input.md> [output.docx]\n"); sys.exit(1)
src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else (src[:-3] if src.lower().endswith(".md") else src) + ".docx"
try:
    r = subprocess.run(["pandoc", src, "-o", out])
except FileNotFoundError:
    sys.stderr.write("[md2docx] 找不到 pandoc\n"); sys.exit(1)
if r.returncode == 0:
    print("已生成 DOCX: " + out)
else:
    sys.exit(r.returncode)
