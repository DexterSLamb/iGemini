#!/usr/bin/env python3
"""Append a product prompt through the Claude Agent SDK's native API.

Identity text intentionally stays outside CloudCLI source. Release launchers set
IGEMINI_SYSTEM_PROMPT_FILE to the versioned product prompt bundled with the app;
development/upstream builds without that variable retain the stock preset.
"""

from __future__ import annotations

from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise AssertionError(
            f"product identity patch anchor mismatch: {path} "
            f"(expected 1, found {count})"
        )
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-cloudcli-product-identity.py <cloudcli-root>")

    target = Path(sys.argv[1]).resolve() / "server/claude-sdk.js"
    replace_once(
        target,
        "import { promises as fs } from 'fs';\n",
        "import { promises as fs, readFileSync } from 'fs';\n",
    )
    replace_once(
        target,
        "const TOOLS_REQUIRING_INTERACTION = new Set(['AskUserQuestion', 'ExitPlanMode']);\n",
        "const TOOLS_REQUIRING_INTERACTION = new Set(['AskUserQuestion', 'ExitPlanMode']);\n\n"
        "function loadProductSystemPrompt() {\n"
        "  const promptPath = process.env.IGEMINI_SYSTEM_PROMPT_FILE;\n"
        "  if (!promptPath) return '';\n\n"
        "  try {\n"
        "    const prompt = readFileSync(promptPath, 'utf8').trim();\n"
        "    if (!prompt) throw new Error('prompt file is empty');\n"
        "    return prompt;\n"
        "  } catch (error) {\n"
        "    throw new Error(`[iGemini] Cannot load product system prompt: ${promptPath}`, { cause: error });\n"
        "  }\n"
        "}\n",
    )
    replace_once(
        target,
        """  sdkOptions.systemPrompt = {
    type: 'preset',
    preset: 'claude_code'
  };
""",
        """  const productSystemPrompt = loadProductSystemPrompt();
  sdkOptions.systemPrompt = {
    type: 'preset',
    preset: 'claude_code',
    ...(productSystemPrompt ? { append: productSystemPrompt } : {})
  };
""",
    )
    print("  Claude Agent SDK systemPrompt.append -> external iGemini product prompt")


if __name__ == "__main__":
    main()
