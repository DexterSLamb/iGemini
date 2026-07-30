#!/usr/bin/env python3
"""Use Claude Code's native prompt-file flag in CloudCLI's integrated shell.

This source patch also centralizes the existing bypass-permissions behavior so
all platforms build the same command instead of rewriting compiled JavaScript
with three platform-specific snippets.
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
            f"shell identity patch anchor mismatch: {path} "
            f"(expected 1, found {count})"
        )
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-cloudcli-shell-identity.py <cloudcli-root>")

    target = (
        Path(sys.argv[1]).resolve()
        / "server/modules/websocket/services/shell-websocket.service.ts"
    )
    replace_once(
        target,
        """/**
 * Resolves provider command line for plain shell and agent-backed shell modes.
 */
function buildShellCommand(""",
        """// [iGemini] Claude shell identity + bypass. The identity text stays in
// an external product file; this code only uses Claude Code's native CLI flag.
function quoteShellArgument(value: string): string {
  if (os.platform() === 'win32') {
    return "'" + value.replace(/'/g, "''") + "'";
  }
  return "'" + value.replace(/'/g, "'\\\"'\\\"'") + "'";
}

function buildClaudeShellCommand(resumeSessionId = ''): string {
  const baseParts = ['claude', '--dangerously-skip-permissions'];
  const productPromptFile = process.env.IGEMINI_SYSTEM_PROMPT_FILE;
  if (productPromptFile) {
    baseParts.push('--append-system-prompt-file', quoteShellArgument(productPromptFile));
  }
  const baseCommand = baseParts.join(' ');
  if (!resumeSessionId) return baseCommand;

  const resumeCommand = `${baseCommand} --resume ${quoteShellArgument(resumeSessionId)}`;
  if (os.platform() === 'win32') {
    return `${resumeCommand}; if ($LASTEXITCODE -ne 0) { ${baseCommand} }`;
  }
  return `${resumeCommand} || ${baseCommand}`;
}

/**
 * Resolves provider command line for plain shell and agent-backed shell modes.
 */
function buildShellCommand(""",
    )
    replace_once(
        target,
        """  const command = initialCommand || 'claude';
  if (resumeSessionId) {
    if (os.platform() === 'win32') {
      return `claude --resume "${resumeSessionId}"; if ($LASTEXITCODE -ne 0) { claude }`;
    }
    return `claude --resume "${resumeSessionId}" || claude`;
  }
  return command;
""",
        """  if (initialCommand) return initialCommand;
  return buildClaudeShellCommand(resumeSessionId);
""",
    )
    print("  CloudCLI Shell -> native identity prompt file + bypass permissions")


if __name__ == "__main__":
    main()
