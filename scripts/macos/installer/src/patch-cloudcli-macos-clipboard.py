#!/usr/bin/env python3
"""Bridge CloudCLI's xterm clipboard state to the native macOS shell.

xterm.js owns terminal selection state, so AppKit cannot validate its standard
``copy:`` menu action from the WKWebView responder chain.  Add a small,
macOS-only adapter that exposes xterm's public selection/paste API to the
native shell and reports focus/selection state through WKScriptMessageHandler.
Browser and non-macOS builds keep their existing clipboard fallback.
"""

from pathlib import Path
import sys


MARKER = "[iGemini] native macOS terminal clipboard bridge"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(
            "usage: patch-cloudcli-macos-clipboard.py <claudecodeui-root>"
        )

    target = (
        Path(sys.argv[1]).resolve()
        / "src/components/shell/hooks/useShellTerminal.ts"
    )
    if not target.is_file():
        raise SystemExit(f"CloudCLI shell terminal source is missing: {target}")

    source = target.read_text(encoding="utf-8")
    if MARKER in source:
        print("  CloudCLI native macOS terminal clipboard bridge already present")
        return

    source = replace_once(
        source,
        """type UseShellTerminalOptions = {
""",
        """// [iGemini] native macOS terminal clipboard bridge. xterm owns its
// selection model, so WKWebView's DOM responder chain cannot validate Copy.
// Keep xterm as the semantic source of truth and expose only its public API.
type IgeminiTerminalClipboardBridge = {
  getSelection: () => string;
  paste: (text: string) => void;
  selectAll: () => void;
};

// Match the native NSString guard: both lengths use UTF-16 code units.
const IGEMINI_TERMINAL_CLIPBOARD_CHARACTER_LIMIT = 8 * 1024 * 1024;

type IgeminiTerminalMessage =
  | { type: 'state'; focused: boolean; hasSelection: boolean }
  | { type: 'copy'; text: string }
  | { type: 'paste' };

type IgeminiTerminalMessageHandler = {
  postMessage: (message: IgeminiTerminalMessage) => void;
};

declare global {
  interface Window {
    __igeminiTerminalClipboard?: IgeminiTerminalClipboardBridge;
  }
}

function getIgeminiTerminalMessageHandler(): IgeminiTerminalMessageHandler | null {
  const host = window as typeof window & {
    webkit?: {
      messageHandlers?: {
        igterminal?: IgeminiTerminalMessageHandler;
      };
    };
  };
  return host.webkit?.messageHandlers?.igterminal ?? null;
}

type UseShellTerminalOptions = {
""",
        "native clipboard types",
    )

    source = replace_once(
        source,
        """    const restoreMacImeInputRecovery = installMacImeInputRecovery(nextTerminal);
    mobileSelectionRef.current = installMobileTerminalSelection(
""",
        """    const restoreMacImeInputRecovery = installMacImeInputRecovery(nextTerminal);

    const nativeTerminalHandler = getIgeminiTerminalMessageHandler();
    let nativeTerminalFocused = false;
    const postNativeTerminalState = () => {
      nativeTerminalHandler?.postMessage({
        type: 'state',
        focused: nativeTerminalFocused,
        hasSelection: nativeTerminalFocused && nextTerminal.hasSelection(),
      });
    };

    const terminalClipboardBridge: IgeminiTerminalClipboardBridge = {
      getSelection: () => nextTerminal.getSelection(),
      paste: (text) => {
        if (
          typeof text === 'string' &&
          text.length > 0 &&
          text.length <= IGEMINI_TERMINAL_CLIPBOARD_CHARACTER_LIMIT
        ) {
          // Use xterm's public paste path so newline normalization and
          // bracketed-paste mode are preserved before onData reaches the pty.
          nextTerminal.paste(text);
        }
      },
      selectAll: () => nextTerminal.selectAll(),
    };
    if (nativeTerminalHandler) {
      window.__igeminiTerminalClipboard = terminalClipboardBridge;
    }

    const terminalTextarea = nextTerminal.textarea;
    const handleNativeTerminalFocus = () => {
      nativeTerminalFocused = true;
      postNativeTerminalState();
    };
    const handleNativeTerminalBlur = () => {
      nativeTerminalFocused = false;
      postNativeTerminalState();
    };
    terminalTextarea?.addEventListener('focus', handleNativeTerminalFocus);
    terminalTextarea?.addEventListener('blur', handleNativeTerminalBlur);
    const nativeSelectionSubscription = nextTerminal.onSelectionChange(
      postNativeTerminalState,
    );
    nativeTerminalFocused = terminalTextarea === document.activeElement;
    postNativeTerminalState();

    mobileSelectionRef.current = installMobileTerminalSelection(
""",
        "native clipboard installation",
    )

    source = replace_once(
        source,
        """      return copyTextToClipboard(selection);
    };
""",
        """      if (nativeTerminalHandler) {
        if (selection.length > IGEMINI_TERMINAL_CLIPBOARD_CHARACTER_LIMIT) {
          return false;
        }
        nativeTerminalHandler.postMessage({ type: 'copy', text: selection });
        return true;
      }

      return copyTextToClipboard(selection);
    };
""",
        "native copy routing",
    )

    source = replace_once(
        source,
        """        if (typeof navigator !== 'undefined' && navigator.clipboard?.readText) {
          navigator.clipboard
            .readText()
            .then((text) => {
              sendSocketMessage(wsRef.current, {
                type: 'input',
                data: text,
              });
            })
            .catch(() => {});
        }

        return false;
""",
        """        if (nativeTerminalHandler) {
          nativeTerminalHandler.postMessage({ type: 'paste' });
          return false;
        }

        if (typeof navigator !== 'undefined' && navigator.clipboard?.readText) {
          navigator.clipboard
            .readText()
            .then((text) => terminalClipboardBridge.paste(text))
            .catch(() => {});
        }

        return false;
""",
        "native paste routing",
    )

    source = replace_once(
        source,
        """      dataSubscription.dispose();
      restoreMacImeInputRecovery();
      closeSocket();
""",
        """      dataSubscription.dispose();
      terminalTextarea?.removeEventListener('focus', handleNativeTerminalFocus);
      terminalTextarea?.removeEventListener('blur', handleNativeTerminalBlur);
      nativeSelectionSubscription.dispose();
      nativeTerminalFocused = false;
      postNativeTerminalState();
      if (window.__igeminiTerminalClipboard === terminalClipboardBridge) {
        delete window.__igeminiTerminalClipboard;
      }
      restoreMacImeInputRecovery();
      closeSocket();
""",
        "native clipboard cleanup",
    )

    target.write_text(source, encoding="utf-8", newline="\n")
    print("  CloudCLI xterm -> native macOS menu/clipboard bridge")


if __name__ == "__main__":
    main()
