#!/usr/bin/env python3
"""Write ~/.codex/hooks.json with absolute paths to the installed plugin hooks.

Codex runs hook commands with the session cwd, so relative plugin paths are
unreliable for local installs. This script is what `make install-local` uses.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: install-hooks.py PLUGIN_ROOT")
    plugin = Path(sys.argv[1]).resolve()
    sh = plugin / "hooks" / "trustguard-hook.sh"
    ps1 = plugin / "hooks" / "trustguard-hook.ps1"
    if not sh.is_file():
        raise SystemExit(f"missing {sh}")

    command = f'sh "{sh}"'
    command_windows = (
        f'powershell -NoProfile -ExecutionPolicy Bypass -File "{ps1}"'
    )
    entry = {
        "hooks": [
            {
                "type": "command",
                "command": command,
                "commandWindows": command_windows,
                "timeout": 30,
                "statusMessage": "TrustGuard",
            }
        ]
    }
    hooks = {
        "description": "TrustGuard AI firewall (installed by make install-local)",
        "hooks": {
            "UserPromptSubmit": [entry],
            "PreToolUse": [entry],
            "PostToolUse": [entry],
        },
    }

    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    codex_home.mkdir(parents=True, exist_ok=True)
    target = codex_home / "hooks.json"
    target.write_text(json.dumps(hooks, indent=2) + "\n")
    print(f"wrote {target}")
    print("Open Codex and run /hooks to review and trust the new definitions.")


if __name__ == "__main__":
    main()
