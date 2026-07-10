#!/usr/bin/env python3
# describe-image <图片> [提示词] — Qwen3-VL 看图 + OCR（跨平台）。
# key/base 读 ~/.config/qwen/{key,base}（绝不入库）。默认模型 qwen3-vl-plus；DESCRIBE_MODEL=qwen3.5-ocr 切纯 OCR。
import sys, json, base64, os, urllib.request, urllib.error, mimetypes

if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
    sys.stderr.write("用法: describe-image <图片> [提示词]\n"); sys.exit(1)
img = sys.argv[1]
prompt = sys.argv[2] if len(sys.argv) > 2 else "请详细描述这张图片的内容；若含文字或表格，请逐字逐项准确读出。"
model = os.environ.get("DESCRIBE_MODEL", "qwen3-vl-plus")

cfg = os.path.expanduser("~/.config/qwen")
key = open(os.path.join(cfg, "key")).read().strip()
basef = os.path.join(cfg, "base")
base = open(basef).read().strip() if os.path.exists(basef) else "https://dashscope.aliyuncs.com/compatible-mode/v1"

mt = mimetypes.guess_type(img)[0] or "image/png"
b64 = base64.b64encode(open(img, "rb").read()).decode()
body = json.dumps({"model": model, "max_tokens": 2000, "messages": [{"role": "user", "content": [
    {"type": "text", "text": prompt},
    {"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (mt, b64)}}]}]}).encode()
req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=body,
    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    d = json.load(urllib.request.urlopen(req, timeout=120))
    print(d["choices"][0]["message"]["content"])
except urllib.error.HTTPError as e:
    sys.stderr.write("API 错误 %d: %s\n" % (e.code, e.read().decode()[:400])); sys.exit(1)
