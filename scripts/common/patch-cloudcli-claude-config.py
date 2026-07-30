#!/usr/bin/env python3
"""Make CloudCLI's direct Claude filesystem reads honor CLAUDE_CONFIG_DIR.

Claude Code itself receives CLAUDE_CONFIG_DIR from the iGemini launcher, but
CloudCLI also reads session, auth, skills, MCP, and agent-state files directly.
Keep this out of the shared white-label patch: it is an iGemini runtime/isolation
adaptation applied by each platform build.
"""

from __future__ import annotations

from pathlib import Path
import sys


def replace_exact(path: Path, old: str, new: str, expected: int = 1) -> None:
    text = path.read_text(encoding="utf-8")
    if text.count(new) == expected:
        return
    count = text.count(old)
    if count == expected:
        path.write_text(text.replace(old, new), encoding="utf-8")
        return
    raise AssertionError(
        f"CLAUDE_CONFIG_DIR patch anchor mismatch: {path} "
        f"(expected {expected}, found {count})"
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-cloudcli-claude-config.py <cloudcli-root>")

    root = Path(sys.argv[1]).resolve()
    claude_home = "(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'))"

    replace_exact(
        root / "server/modules/providers/list/claude/claude-session-synchronizer.provider.ts",
        "path.join(os.homedir(), '.claude')",
        claude_home,
    )
    replace_exact(
        root / "server/modules/providers/services/sessions-watcher.service.ts",
        "path.join(os.homedir(), '.claude', 'projects')",
        f"path.join({claude_home}, 'projects')",
    )
    replace_exact(
        root / "server/modules/providers/list/claude/claude-skills.provider.ts",
        "path.join(os.homedir(), '.claude')",
        claude_home,
    )
    replace_exact(
        root / "server/modules/providers/list/claude/claude-auth.provider.ts",
        "path.join(os.homedir(), '.claude', 'settings.json')",
        f"path.join({claude_home}, 'settings.json')",
    )
    replace_exact(
        root / "server/modules/providers/list/claude/claude-auth.provider.ts",
        "path.join(os.homedir(), '.claude', '.credentials.json')",
        f"path.join({claude_home}, '.credentials.json')",
    )

    claude_state = (
        "(process.env.CLAUDE_CONFIG_DIR "
        "? path.join(process.env.CLAUDE_CONFIG_DIR, '.claude.json') "
        ": path.join(os.homedir(), '.claude.json'))"
    )
    replace_exact(
        root / "server/modules/providers/list/claude/claude-mcp.provider.ts",
        "path.join(os.homedir(), '.claude.json')",
        claude_state,
        expected=2,
    )
    replace_exact(
        root / "server/claude-sdk.js",
        "path.join(os.homedir(), '.claude.json')",
        claude_state,
    )
    replace_exact(
        root / "server/utils/mcp-detector.js",
        "path.join(homeDir, '.claude.json')",
        claude_state,
    )
    replace_exact(
        root / "server/utils/mcp-detector.js",
        "path.join(homeDir, '.claude', 'settings.json')",
        f"path.join({claude_home}, 'settings.json')",
    )
    replace_exact(
        root / "server/routes/agent.js",
        "path.join(os.homedir(), '.claude', 'sessions', sessionId)",
        f"path.join({claude_home}, 'sessions', sessionId)",
    )
    replace_exact(
        root / "server/routes/agent.js",
        "path.join(os.homedir(), '.claude', 'external-projects', repoHash)",
        f"path.join({claude_home}, 'external-projects', repoHash)",
    )
    replace_exact(
        root / "server/routes/agent.js",
        "if (!projectPath.includes('.claude/external-projects')) {",
        (
            "const externalProjectsRoot = path.resolve("
            f"{claude_home}, 'external-projects');\n"
            "    const relativeProjectPath = path.relative(externalProjectsRoot, path.resolve(projectPath));\n"
            "    if (!relativeProjectPath || relativeProjectPath.startsWith('..') || "
            "path.isAbsolute(relativeProjectPath)) {"
        ),
    )
    replace_exact(
        root / "server/routes/commands.js",
        'path.join(homeDir, ".claude", "commands")',
        (
            "path.join(process.env.CLAUDE_CONFIG_DIR || "
            "path.join(os.homedir(), '.claude'), \"commands\")"
        ),
    )
    replace_exact(
        root / "server/routes/commands.js",
        'path.join(os.homedir(), ".claude", "commands")',
        f"path.join({claude_home}, \"commands\")",
    )
    replace_exact(
        root / "server/index.js",
        "path.join(homeDir, '.claude', 'projects', encodedPath)",
        f"path.join({claude_home}, 'projects', encodedPath)",
    )
    replace_exact(
        root / "server/cli.js",
        "path.join(os.homedir(), '.claude', 'projects')",
        f"path.join({claude_home}, 'projects')",
    )

    print(
        "  CloudCLI Claude paths -> CLAUDE_CONFIG_DIR "
        "(sessions/watcher/auth/skills/MCP/commands/agent/CLI)"
    )


if __name__ == "__main__":
    main()
