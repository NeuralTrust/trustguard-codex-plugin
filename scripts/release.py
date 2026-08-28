#!/usr/bin/env python3
"""Release plumbing for the TrustGuard Codex plugin.

`main` is covered by an org ruleset that requires a pull request, so the
Release workflow can not commit the pinned bootstraps itself. It instead
derives what to do from the repository state, and these subcommands do the
file surgery:

    plan          print mode=prepare|publish and version=X.Y.Z for the workflow
    set-version   write a version into the four files that carry one
    pin           write the checksums of dist/ into the bootstrap scripts
    verify        assert the bootstraps already carry the checksums of dist/

Run from the repository root.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

PLUGIN_JSON = Path("trustguard/.codex-plugin/plugin.json")
MAIN_GO = Path("cli/main.go")
HOOK_SH = Path("trustguard/hooks/trustguard-hook.sh")
HOOK_PS1 = Path("trustguard/hooks/trustguard-hook.ps1")

# Platforms the bootstraps can install, mapped to the artifact suffix in dist/.
PLATFORMS = {
    "darwin_amd64": "darwin_amd64",
    "darwin_arm64": "darwin_arm64",
    "linux_amd64": "linux_amd64",
    "linux_arm64": "linux_arm64",
    "windows_amd64": "windows_amd64.exe",
    "windows_arm64": "windows_arm64.exe",
}

VERSION_PATTERNS = {
    PLUGIN_JSON: (r'"version":\s*"([^"]*)"', 0),
    MAIN_GO: (r'const integrationVersion = "([^"]*)"', 0),
    HOOK_SH: (r'^VERSION="([^"]*)"$', re.M),
    HOOK_PS1: (r"^\$Version = '([^']*)'$", re.M),
}

# The SHA-256 tables. In the shell bootstrap they are a contiguous run of
# SHA256_* assignments; the PowerShell one is a hashtable literal.
SH_TABLE = r'^(?:SHA256_[a-z0-9_]+="[a-f0-9]*"\n)+'
PS_TABLE = r"\$Sha256 = @\{[^}]*\}"


def _capture(path: Path, pattern: str, flags: int = 0) -> str:
    match = re.search(pattern, path.read_text(), flags)
    if not match:
        raise SystemExit(f"{path}: no match for {pattern!r}")
    return match.group(1)


def _replace(path: Path, pattern: str, value: str, flags: int = 0) -> None:
    text, n = re.subn(pattern, lambda _: value, path.read_text(), count=1, flags=flags)
    if n != 1:
        raise SystemExit(f"{path}: no match for {pattern!r} (replacements={n})")
    path.write_text(text)


def read_versions() -> dict[Path, str]:
    """Version currently declared by each file that carries one."""
    return {
        path: _capture(path, pattern, flags)
        for path, (pattern, flags) in VERSION_PATTERNS.items()
    }


def set_version(version: str) -> None:
    _replace(PLUGIN_JSON, r'"version":\s*"[^"]*"', f'"version": "{version}"')
    _replace(MAIN_GO, r'const integrationVersion = "[^"]*"', f'const integrationVersion = "{version}"')
    _replace(HOOK_SH, r'^VERSION="[^"]*"$', f'VERSION="{version}"', re.M)
    _replace(HOOK_PS1, r"^\$Version = '[^']*'$", f"$Version = '{version}'", re.M)


def built_checksums(version: str, dist: Path = Path("dist")) -> dict[str, str]:
    """SHA-256 of every platform binary in dist/, keyed by platform."""
    sums = {}
    for line in (dist / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        sums[name.strip().lstrip("*")] = digest

    checksums = {}
    for platform, suffix in PLATFORMS.items():
        artifact = f"trustguard-codex_{version}_{suffix}"
        if artifact not in sums:
            raise SystemExit(f"{dist}/SHA256SUMS: missing {artifact}")
        checksums[platform] = sums[artifact]
    return checksums


def pinned_checksums() -> dict[str, str]:
    """SHA-256 currently pinned in the shell bootstrap, keyed by platform."""
    return dict(re.findall(r'^SHA256_([a-z0-9_]+)="([a-f0-9]*)"$', HOOK_SH.read_text(), re.M))


def pin(version: str) -> None:
    checksums = built_checksums(version)
    _replace(
        HOOK_SH,
        SH_TABLE,
        "".join(f'SHA256_{platform}="{digest}"\n' for platform, digest in checksums.items()),
        re.M,
    )
    _replace(
        HOOK_PS1,
        PS_TABLE,
        "$Sha256 = @{\n"
        f"    'amd64' = '{checksums['windows_amd64']}'\n"
        f"    'arm64' = '{checksums['windows_arm64']}'\n"
        "}",
        re.S,
    )


def verify(version: str) -> None:
    """Fail unless the committed pins describe the binaries just rebuilt.

    A mismatch means the build is not reproducible across runs (usually a
    toolchain drift between the run that opened the release PR and this one),
    so publishing would ship binaries the bootstraps refuse to install.
    """
    stale = {path: found for path, found in read_versions().items() if found != version}
    if stale:
        listing = ", ".join(f"{path} declares {found}" for path, found in stale.items())
        raise SystemExit(f"expected every file to declare {version}: {listing}")

    built, pinned = built_checksums(version), pinned_checksums()
    drifted = [p for p in PLATFORMS if pinned.get(p) != built[p]]
    if drifted:
        listing = "\n".join(f"  {p}: pinned {pinned.get(p, 'none')} built {built[p]}" for p in drifted)
        raise SystemExit(f"rebuilt binaries do not match the pinned checksums:\n{listing}")

    windows = dict(re.findall(r"^\s*'(amd64|arm64)' = '([a-f0-9]*)'$", HOOK_PS1.read_text(), re.M))
    for arch in ("amd64", "arm64"):
        if windows.get(arch) != built[f"windows_{arch}"]:
            raise SystemExit(f"{HOOK_PS1}: {arch} checksum does not match the rebuilt binary")

    print(f"pins verified against the rebuilt binaries for {version}")


def _released() -> set[str]:
    tags = subprocess.run(
        ["git", "tag", "-l", "v[0-9]*"], capture_output=True, text=True, check=True
    ).stdout.split()
    return {tag[1:] for tag in tags if re.fullmatch(r"v\d+\.\d+\.\d+", tag)}


def _order(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def plan() -> None:
    """Decide whether main is waiting to be published or needs a release PR."""
    versions = read_versions()
    declared = versions[PLUGIN_JSON]
    released = _released()

    if len(set(versions.values())) == 1 and declared not in released:
        mode, version, why = "publish", declared, f"v{declared} is pinned but not tagged"
    else:
        base = max([declared, *released], key=_order)
        if base in released:
            major, minor, patch = _order(base)
            version = f"{major}.{minor}.{patch + 1}"
            why = f"v{base} is released; next patch is v{version}"
        else:
            version = base
            why = f"v{base} is bumped but not pinned consistently"
        mode = "prepare"

    print(why, file=sys.stderr)
    print(f"mode={mode}")
    print(f"version={version}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("plan")
    for command in ("set-version", "pin", "verify"):
        sub.add_parser(command).add_argument("version")

    args = parser.parse_args()
    if args.command == "plan":
        plan()
    elif args.command == "set-version":
        set_version(args.version)
    elif args.command == "pin":
        pin(args.version)
    elif args.command == "verify":
        verify(args.version)


if __name__ == "__main__":
    main()
