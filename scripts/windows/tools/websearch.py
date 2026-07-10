#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# websearch —— Serper→DuckDuckGo 兜底网页搜索，供 claudecodeui 里的 CC 调用。
#
# 用途：CC 自带的 WebSearch（由 DeepSeek 服务端执行）若**报错 / 限流 / 返空**，
#       就改调本命令拿到一份可继续 WebFetch / 引用的搜索结果。
#
# 用法：
#   websearch "查询词"            # 默认 8 条
#   websearch "查询词" 5          # 指定条数
#   WEBSEARCH_FORCE_DDG=1 websearch "查询词"   # 跳过 Serper、直接用 DDG（自测用）
#
# 后端链：Serper(Google，需 key) → DuckDuckGo(零 key 兜底，质量较低)。
#   - Serper key 读 ~/.config/deepseek/serper_key（无则跳过，直接 DDG）。
# 退出码：0=有结果；1=两路都空/失败；2=用法错。
# 纯 Python 标准库（urllib），无第三方依赖；系统 python3 即可。

import sys, os, json, re, html, urllib.request, urllib.parse

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/16.6 Safari/605.1.15")
# DDG 对“瘦请求头”的脚本会掐连接(SSL EOF)；补 Accept/Accept-Language + 完整 UA 才稳。
DDG_HEADERS = {"User-Agent": UA,
               "Accept": "text/html,application/xhtml+xml",
               "Accept-Language": "en-US,en;q=0.9"}
KEYFILE = os.path.expanduser("~/.config/deepseek/serper_key")


def _fetch(url, data=None, headers=None, timeout=20):
    req = urllib.request.Request(url, data=data, headers=headers or {},
                                 method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def serper(query, key, n):
    body = json.dumps({"q": query, "num": n}).encode("utf-8")
    raw = _fetch("https://google.serper.dev/search", data=body,
                 headers={"X-API-KEY": key, "Content-Type": "application/json"})
    d = json.loads(raw)
    out = []
    ab = d.get("answerBox") or {}
    ans = ab.get("answer") or ab.get("snippet")
    if ans:
        out.append((("[答案] " + (ab.get("title") or "")).strip(), ab.get("link", ""), ans))
    for it in (d.get("organic") or [])[:n]:
        out.append((it.get("title", ""), it.get("link", ""), it.get("snippet", "")))
    return out


def ddg(query, n):
    raw = _fetch("https://html.duckduckgo.com/html/?" +
                 urllib.parse.urlencode({"q": query, "kl": "wt-wt"}),
                 headers=DDG_HEADERS)
    out = []
    # 逐结果块解析，保持 标题/URL/摘要 对齐
    for block in re.split(r'<div class="result\b', raw)[1:]:
        am = re.search(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not am:
            continue
        url = html.unescape(am.group(1))
        mm = re.search(r'uddg=([^&]+)', url)          # DDG 重定向 → 还原真实 URL
        if mm:
            url = urllib.parse.unquote(mm.group(1))
        title = html.unescape(re.sub(r"<[^>]+>", "", am.group(2))).strip()
        sm = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', block, re.S)
        snip = html.unescape(re.sub(r"<[^>]+>", "", sm.group(1))).strip() if sm else ""
        out.append((title, url, snip))
        if len(out) >= n:
            break
    return out


def fmt(results, backend):
    if not results:
        return None
    lines = ["# websearch 结果（后端: %s）" % backend, ""]
    for i, (t, u, s) in enumerate(results, 1):
        lines.append("%d. %s" % (i, t))
        if u:
            lines.append("   %s" % u)
        if s:
            lines.append("   %s" % s)
        lines.append("")
    return "\n".join(lines).rstrip()


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        sys.stderr.write('用法: websearch "查询词" [结果数]\n')
        sys.exit(2)
    query = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 8
    force_ddg = os.environ.get("WEBSEARCH_FORCE_DDG") == "1"

    # 1) Serper（主）
    if not force_ddg and os.path.exists(KEYFILE):
        try:
            key = open(KEYFILE).read().strip()
            txt = fmt(serper(query, key, n), "Serper/Google")
            if txt:
                print(txt)
                return
            sys.stderr.write("[websearch] Serper 返空，回退 DuckDuckGo\n")
        except Exception as e:
            sys.stderr.write("[websearch] Serper 失败(%s)，回退 DuckDuckGo\n" % e)
    elif not force_ddg:
        sys.stderr.write("[websearch] 无 serper_key，直接用 DuckDuckGo\n")

    # 2) DuckDuckGo（兜底）
    try:
        txt = fmt(ddg(query, n), "DuckDuckGo")
        if txt:
            print(txt)
            return
        sys.stderr.write("[websearch] DuckDuckGo 也返空\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write("[websearch] DuckDuckGo 失败(%s)\n" % e)
        sys.exit(1)


if __name__ == "__main__":
    main()
