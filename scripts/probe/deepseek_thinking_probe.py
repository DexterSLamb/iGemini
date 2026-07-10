#!/usr/bin/env python3
"""探针：验证 DeepSeek v4-pro 在「多轮 + 工具 + thinking」下的 400 行为，
判定「回填 thinking 块」的本地代理方案（解法 A）是否成立。零 Claude Code 依赖。

用法：
  python3 deepseek_thinking_probe.py [--model deepseek-v4-pro]
Key 读取：环境变量 DEEPSEEK_API_KEY → ~/.config/deepseek/key
成本：3 次小请求，约几分钱。
"""
import os, sys, json, argparse, urllib.request, urllib.error

BASE = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com/anthropic")
URL = BASE.rstrip("/") + "/v1/messages"

TOOL = {
    "name": "get_weather",
    "description": "Get the current weather for a city.",
    "input_schema": {
        "type": "object",
        "properties": {"location": {"type": "string"}},
        "required": ["location"],
    },
}


def get_key():
    k = os.environ.get("DEEPSEEK_API_KEY")
    if k:
        return k.strip()
    p = os.path.expanduser("~/.config/deepseek/key")
    if os.path.exists(p):
        txt = open(p, encoding="utf-8", errors="replace").read()
        for line in txt.splitlines():
            line = line.strip()
            if line.startswith("sk-"):
                return line
        if txt.strip():
            return txt.strip().splitlines()[-1].strip()
    sys.exit("未找到 DeepSeek key（设 DEEPSEEK_API_KEY，或写入 ~/.config/deepseek/key）")


def post(key, body):
    req = urllib.request.Request(
        URL, data=json.dumps(body).encode(), method="POST",
        headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore")
    except Exception as e:
        return 0, str(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="deepseek-v4-pro")
    a = ap.parse_args()
    key = get_key()
    print(f"endpoint: {URL}\nmodel: {a.model}\n")

    user1 = {"role": "user",
             "content": "What is the weather in Paris right now? Use the get_weather tool."}
    base = {"model": a.model, "max_tokens": 2000,
            "thinking": {"type": "enabled", "budget_tokens": 1024},
            "tools": [TOOL]}

    # ---- Turn 1 ----
    print("== Turn 1 ==")
    st, resp = post(key, {**base, "messages": [user1]})
    if st != 200:
        print(f"[turn1] HTTP {st}: {str(resp)[:600]}")
        sys.exit("turn1 失败：先解决基础调用（thinking 配置 / 鉴权 / 模型名）。")
    content = resp.get("content", [])
    types = [b.get("type") for b in content]
    has_thinking = any(b.get("type") == "thinking" for b in content)
    tool_use = next((b for b in content if b.get("type") == "tool_use"), None)
    print(f"  stop_reason={resp.get('stop_reason')}  blocks={types}  "
          f"thinking={'yes' if has_thinking else 'NO'}  tool_use={'yes' if tool_use else 'NO'}")
    if not tool_use:
        sys.exit("  turn1 没有 tool_use，无法构造 turn2；换更强提示或加 tool_choice 后重试。")
    if not has_thinking:
        print("  [注意] turn1 无 thinking 块——该端点可能未真正开启 thinking；"
              "若如此，400 或本就不触发，v4-pro 也许可直接用（仍需多轮实测）。")

    tr = {"role": "user",
          "content": [{"type": "tool_result", "tool_use_id": tool_use["id"],
                       "content": "18°C, sunny"}]}

    # ---- Turn 2a：保留真实 thinking 块（解法 A）----
    print("\n== Turn 2a：保留真实 thinking 块（解法 A） ==")
    st2a, resp2a = post(key, {**base, "messages": [user1, {"role": "assistant", "content": content}, tr]})
    print(f"  HTTP {st2a}" + ("" if st2a == 200 else f": {str(resp2a)[:500]}"))

    # ---- Turn 2b：剥离 thinking 块（复现 CC 现状）----
    print("\n== Turn 2b：剥离 thinking 块（复现 CC 现状） ==")
    stripped = [b for b in content if b.get("type") != "thinking"]
    st2b, resp2b = post(key, {**base, "messages": [user1, {"role": "assistant", "content": stripped}, tr]})
    print(f"  HTTP {st2b}" + ("" if st2b == 200 else f": {str(resp2b)[:500]}"))

    # ---- 判定 ----
    print("\n== 判定 ==")
    if st2a == 200 and st2b != 200:
        print("  ✅ 回填→200，剥离→失败。解法 A（回填 shim）成立，且确为根因。")
    elif st2a == 200 and st2b == 200:
        print("  ✅ 两者都 200：该端点未强制 thinking 回填，v4-pro 可能无需 shim 直接用（多轮再验证）。")
    else:
        print("  ❌ 即便回填真实 thinking 仍非 200：解法 A 不成立 → 只能解法 B（关 thinking）或退 flash。看上面 2a 错误体。")


if __name__ == "__main__":
    main()
