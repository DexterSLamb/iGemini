# iGemini

**A local, browser-based AI assistant.** Open it, and from your browser you can
chat with an AI, let it search the web, read images (OCR), read/write documents,
run code, and use a terminal — all powered by [Claude Code](https://claude.com/claude-code)
as the agent engine, with **DeepSeek** as the model backend.

Everything the app needs (runtime, model toolchain, capability dependencies) is
bundled into the offline installer. Install once, and it works — you only supply
one thing: an **API key** (stored on your machine, never uploaded).

> **Disclaimer.** iGemini is a hobby / educational project. It is **not**
> affiliated with, endorsed by, or connected to Google (Gemini), Anthropic
> (Claude), or Apple (Siri).

> **Built on [claudecodeui](https://github.com/siteboon/claudecodeui)** by
> siteboon (AGPL-3.0), white-labeled to iGemini. See [`NOTICE`](NOTICE).

---

## What this repository is

This is the **orchestration layer**. It stitches three things into a
"control Claude Code from a web page, with DeepSeek as the model" system:

1. **Claude Code (CC)** CLI — the agent engine.
2. **DeepSeek** — used as CC's model backend via its Anthropic-compatible
   endpoint `https://api.deepseek.com/anthropic`.
3. **claudecodeui** (siteboon, AGPL-3.0) — the web UI, white-labeled to iGemini
   (see [`vendor/`](vendor/) and `NOTICE`). It `spawn`s the `claude` CLI.

### Data flow

```
Browser  ⇄  claudecodeui (iGemini)  ──spawn──▶  claude CLI  ──env──▶  api.deepseek.com/anthropic
```

The web layer spawns `claude` as a child process; the child inherits the
launcher's environment, so injecting the DeepSeek env at start-up is enough to
route the whole thing through DeepSeek. The service binds `127.0.0.1:8888`
(local only). Keys are injected at runtime from `~/.config/deepseek/key` — never
hard-coded, never committed.

This repository does **not** contain the source of Claude Code or claudecodeui.
claudecodeui is fetched at a pinned upstream commit and white-labeled by applying
[`vendor/igemini-claudecodeui.patch`](vendor/igemini-claudecodeui.patch)
(applied, never forked).

---

## Layout

| Path | What |
|---|---|
| `scripts/macos/` | macOS: native **WKWebView** shell + one-click offline `.pkg` installer |
| `scripts/windows/` | Windows (native, not WSL2): native **WebView2** shell + one-click `setup.exe` (Inno Setup) |
| `scripts/linux/` | Linux: backend + native **WebKitGTK** shell |
| `scripts/*/tools/` | Five capability tools (web search, doc parsing, PDF/Word export, image OCR) |
| `config/` | Env / settings templates (placeholders only) |
| `vendor/` | The white-label patch + notes |

Each platform's native shell offers the same v1.1.0 feature set: in-app API-key
form (with live key validation), auto-login straight into chat, an About panel,
window zoom, and a startup-timeout hint.

---

## Build

Each platform builds a self-contained offline installer. Run the build on a
machine of the target OS.

- **macOS** (on Apple Silicon; cross-compiles the Intel shell):
  ```sh
  bash scripts/macos/installer/build-pkg.sh arm64   # → iGemini-Installer-arm64-vX.Y.Z.pkg
  bash scripts/macos/installer/build-pkg.sh x64      # → Intel
  ```
- **Windows** (native x64):
  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\windows\installer\build-installer.ps1
  iscc scripts\windows\installer\iGemini.iss          # → iGemini-Setup-x64-vX.Y.Z.exe
  ```
- **Linux** (Debian / Deepin family):
  ```sh
  bash scripts/linux/setup.sh                          # backend + tools + service
  bash scripts/linux/shell-app/build-appimage.sh       # optional thin AppImage
  # native shell: scripts/linux/shell-app/igemini-shell.py (GTK3 + WebKitGTK)
  ```

> In regions where the default package/binary sources are slow, pass a proxy
> (e.g. `PROXY=http://127.0.0.1:7897 bash …` / `-Proxy …`). The build otherwise
> connects directly.

The single-source version number lives in `scripts/<os>/installer/VERSION`.

## Configure keys

Keys live under `~/.config` (Windows: `%USERPROFILE%\.config`) and are read at
runtime — the installers collect them for you (Windows: an installer page;
macOS/Linux: a first-run form in the shell). To change them later, use the
shell's **Configure keys…** entry, or edit the files directly:

- `~/.config/deepseek/key` — DeepSeek (required)
- `~/.config/deepseek/serper_key` — Serper (optional, better web search)
- `~/.config/qwen/key`, `~/.config/qwen/base` — Qwen (optional, image OCR)

`~/.config/deepseek/base` can override the DeepSeek endpoint (for pointing at a
different backend).

---

## License

This repository is licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)).
It includes a patch derived from claudecodeui (© siteboon, AGPL-3.0); see
[`NOTICE`](NOTICE) for full third-party attribution and the corresponding-source
statement.
