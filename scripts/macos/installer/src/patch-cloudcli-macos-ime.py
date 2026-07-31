#!/usr/bin/env python3
"""Patch CloudCLI's xterm integration for macOS IME keyCode=229 loss.

xterm.js 5.5.0 can discard an ``insertText`` input when a macOS IME reports
keyCode=229 and the previous keydown flag is still set.  The upstream handler
returns false without emitting terminal data in that exact case.  Keep the
upstream path intact and recover only an otherwise-unhandled, non-composing
insertText event.
"""

import json
from pathlib import Path
import sys


MARKER = "[iGemini] macOS xterm IME keyCode=229 recovery"
SUPPORTED_XTERM_VERSION = "5.5.0"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-cloudcli-macos-ime.py <claudecodeui-root>")

    root = Path(sys.argv[1]).resolve()
    target = root / "src/components/shell/hooks/useShellTerminal.ts"
    if not target.is_file():
        raise SystemExit(f"CloudCLI shell terminal source is missing: {target}")

    lock_path = root / "package-lock.json"
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        xterm_version = lock["packages"]["node_modules/@xterm/xterm"]["version"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        raise SystemExit(f"cannot verify pinned @xterm/xterm from {lock_path}: {exc}")
    if xterm_version != SUPPORTED_XTERM_VERSION:
        raise SystemExit(
            "macOS IME recovery only supports @xterm/xterm "
            f"{SUPPORTED_XTERM_VERSION}; package-lock pins {xterm_version!r}"
        )

    source = target.read_text(encoding="utf-8")
    if MARKER in source:
        print("  CloudCLI macOS xterm IME recovery already present")
        return

    source = replace_once(
        source,
        """const ClipboardAddonCtor = ClipboardAddon as unknown as new (
  base64?: unknown,
  provider?: IClipboardProvider,
) => ClipboardAddon;
""",
        """const ClipboardAddonCtor = ClipboardAddon as unknown as new (
  base64?: unknown,
  provider?: IClipboardProvider,
) => ClipboardAddon;

type XtermInternalCore = {
  _inputEvent: (event: InputEvent) => boolean;
  _keyDownSeen: boolean;
  _keyPressHandled: boolean;
  _unprocessedDeadKey: boolean;
  _compositionHelper?: {
    isComposing?: boolean;
    _isSendingComposition?: boolean;
  };
  optionsService: { rawOptions: { screenReaderMode?: boolean } };
  coreService: { triggerDataEvent: (data: string, wasUserInput: boolean) => void };
  cancel: (event: Event) => void;
};

// [iGemini] macOS xterm IME keyCode=229 recovery. xterm.js 5.5.0 can
// deliberately return "not handled" for a composed insertText event when a
// macOS IME leaves _keyDownSeen set (xtermjs/xterm.js#5887). Preserve xterm's
// normal path first, then recover only that dropped, non-composing input.
function installMacImeInputRecovery(terminal: Terminal): () => void {
  const core = (terminal as unknown as { _core?: XtermInternalCore })._core;
  if (!core || typeof core._inputEvent !== 'function') {
    return () => {};
  }

  const originalInputEvent = core._inputEvent;
  const patchedInputEvent = function (this: XtermInternalCore, event: InputEvent): boolean {
    const handled = originalInputEvent.call(this, event);
    if (handled) {
      return true;
    }

    const composition = this._compositionHelper;
    const isDroppedMacImeText = Boolean(
      event.data &&
      event.inputType === 'insertText' &&
      event.composed &&
      this._keyDownSeen &&
      !this._keyPressHandled &&
      !event.isComposing &&
      !composition?.isComposing &&
      !composition?._isSendingComposition &&
      !this.optionsService.rawOptions.screenReaderMode
    );
    if (!isDroppedMacImeText) {
      return false;
    }

    this._unprocessedDeadKey = false;
    this.coreService.triggerDataEvent(event.data!, true);
    this.cancel(event);
    return true;
  };

  core._inputEvent = patchedInputEvent;
  return () => {
    if (core._inputEvent === patchedInputEvent) {
      core._inputEvent = originalInputEvent;
    }
  };
}
""",
        "IME helper insertion",
    )

    source = replace_once(
        source,
        """    nextTerminal.open(terminalContainer);
    mobileSelectionRef.current = installMobileTerminalSelection(
""",
        """    nextTerminal.open(terminalContainer);
    const restoreMacImeInputRecovery = installMacImeInputRecovery(nextTerminal);
    mobileSelectionRef.current = installMobileTerminalSelection(
""",
        "IME helper installation",
    )

    source = replace_once(
        source,
        """      dataSubscription.dispose();
      closeSocket();
      disposeTerminal();
""",
        """      dataSubscription.dispose();
      restoreMacImeInputRecovery();
      closeSocket();
      disposeTerminal();
""",
        "IME helper cleanup",
    )

    target.write_text(source, encoding="utf-8", newline="\n")
    print("  CloudCLI xterm -> macOS IME keyCode=229 dropped-input recovery")


if __name__ == "__main__":
    main()
