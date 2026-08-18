#!/usr/bin/env python3
"""Show what changed between the pinned OpenCore and a target release.

This is the mandatory first step before bumping scripts/component-versions.env.
It does not change any files unless --output is given.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
import plistlib
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
VERSIONS_FILE = ROOT / "scripts" / "component-versions.env"
KVM_WORDS = (
    "virtio",
    "qemu",
    "kvm",
    "hyper-v",
    "hypervisor",
    "cpu",
    "smbios",
    "nvram",
    "unload",
    "commpage",
    "xhci",
    "bluetooth",
    "trim",
    "tsc",
    "slide",
    "virtual map",
    "boot device",
    "apfs",
    "tahoe",
    "sequoia",
    "sonoma",
    "ventura",
    "monterey",
    "secure boot",
    "vault",
    "picker",
    "ocvalidate",
    "sample.plist",
    "configuration.pdf",
)

SKIP_CHILD_FILL = {
    ("DeviceProperties", "Add"),
    ("DeviceProperties", "Delete"),
    ("NVRAM", "Add"),
    ("NVRAM", "Delete"),
    ("NVRAM", "LegacySchema"),
}

HEADING_RE = re.compile(r"^#### v(\d+\.\d+\.\d+)\s*$")


def parse_version(text: str) -> tuple[int, ...]:
    parts = []
    for bit in text.strip().lstrip("v").split("."):
        if not bit.isdigit():
            break
        parts.append(int(bit))
    if len(parts) < 2:
        raise ValueError(f"not an OpenCore version: {text}")
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def version_key(text: str) -> tuple[int, ...]:
    return parse_version(text)


def read_pin(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("OPENCORE_VERSION="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"OPENCORE_VERSION not found in {path}")


def github_headers() -> dict[str, str]:
    headers = {
        "User-Agent": "KVM-Opencore-upgrade-review",
        "Accept": "application/vnd.github+json",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def latest_tag(repo: str) -> str:
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(url, headers=github_headers())
    with urllib.request.urlopen(req) as resp:
        data = json.load(resp)
    return str(data["tag_name"])


def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers=github_headers())
    with urllib.request.urlopen(req) as resp:
        return resp.read().decode("utf-8", errors="replace")


def fetch_bytes(url: str) -> bytes:
    req = urllib.request.Request(url, headers=github_headers())
    with urllib.request.urlopen(req) as resp:
        return resp.read()


def split_changelog(text: str) -> list[tuple[str, str]]:
    sections: list[tuple[str, str]] = []
    current: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match:
            if current is not None:
                sections.append((current, "\n".join(buf).strip()))
            current = match.group(1)
            buf = []
            continue
        if current is not None:
            buf.append(line)
    if current is not None:
        sections.append((current, "\n".join(buf).strip()))
    return sections


def relevant_sections(sections: list[tuple[str, str]], start: str, end: str) -> list[tuple[str, str]]:
    lo = version_key(start)
    hi = version_key(end)
    picked: list[tuple[str, str]] = []
    for ver, body in sections:
        key = version_key(ver)
        if lo < key <= hi:
            picked.append((ver, body))
    picked.sort(key=lambda item: version_key(item[0]))
    return picked


def highlight(body: str) -> tuple[list[str], list[str]]:
    kvm_lines: list[str] = []
    other: list[str] = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            continue
        lowered = line.lower()
        if any(word in lowered for word in KVM_WORDS):
            kvm_lines.append(line)
        else:
            other.append(line)
    return kvm_lines, other


def schema_keys(obj: Any, path: tuple[str, ...] = ()) -> set[str]:
    keys: set[str] = set()
    if isinstance(obj, dict):
        if path in SKIP_CHILD_FILL:
            keys.add("/".join(path))
            return keys
        for key, value in obj.items():
            if isinstance(key, str) and key.startswith("#"):
                continue
            keys |= schema_keys(value, path + (str(key),))
        if not obj:
            keys.add("/".join(path))
        return keys
    if path:
        keys.add("/".join(path))
    return keys


def load_plist_any(path: Path | None, raw: bytes | None) -> dict[str, Any]:
    data = plistlib.loads(raw) if raw is not None else plistlib.load(path.open("rb"))  # type: ignore[arg-type]
    if not isinstance(data, dict):
        raise SystemExit("plist is not a dictionary")
    return data


def render(
    pinned: str,
    target: str,
    sections: list[tuple[str, str]],
    added_keys: list[str],
    removed_keys: list[str],
) -> str:
    lines: list[str] = []
    lines.append(f"# OpenCore upgrade review  {pinned} → {target}")
    lines.append("")
    lines.append("中文在前，English follows each block. Do not skip this file before publishing.")
    lines.append("先读本文再发版，不要只换二进制。")
    lines.append("")
    lines.append("## 结论 / Verdict")
    lines.append("")
    if pinned == target:
        lines.append(f"- 核心版本没有变化（仍是 `{target}`）。仍要跑 KVM 契约检查，并确认 kext 版本。")
        lines.append(f"- No OpenCore core delta (still `{target}`). Still run the KVM contract check and review kext pins.")
    else:
        lines.append(f"- 必须阅读下面列出的 `v{pinned}` 之后、`v{target}` 及以前的全部官方变更。")
        lines.append(f"- You must read every official change after `v{pinned}` through `v{target}`.")
        lines.append("- 禁止整份覆盖 `Sample.plist`。只允许补缺失 schema 键，KVM 契约值不能被 Sample 默认值改掉。")
        lines.append("- Never replace `config.plist` with `Sample.plist`. Only fill missing schema keys; KVM contract values stay.")
    lines.append("")
    lines.append("## 升级前必做 / Required before publish")
    lines.append("")
    lines.append("1. 读完本文里标了 **[KVM]** 的条目，并打开官方 `Docs/Changelog.md` / `Docs/Differences.pdf`。")
    lines.append("   Read every **[KVM]** line below and the official changelog / Differences.pdf.")
    lines.append("2. `python3 scripts/check-kvm-compat.py EFI/OC/config.plist` 必须通过。")
    lines.append("   The KVM contract check must pass.")
    lines.append("3. 用目标版本自带的 `ocvalidate` 校验 `EFI/OC/config.plist`。")
    lines.append("   Validate with the **target** `ocvalidate`, not an older copy.")
    lines.append("4. 先打 **draft** Release，虚拟机里保留旧的 OpenCore 盘作为回滚。")
    lines.append("   Publish a **draft** first and keep the previous OpenCore disk attached for rollback.")
    lines.append("5. 至少验证：选择菜单出现、能进已安装的 macOS、能进恢复/安装器（如适用）。")
    lines.append("   Smoke-test: picker shows, installed macOS boots, Recovery/installer still opens if you use them.")
    lines.append("6. 通过后再改 `scripts/component-versions.env` 并正式发版。")
    lines.append("   Only then bump `scripts/component-versions.env` and publish.")
    lines.append("")

    if added_keys:
        lines.append("## 目标 Sample.plist 多出来的键 / New Sample.plist keys")
        lines.append("")
        lines.append("这些键当前仓库 `config.plist` 里没有。打包脚本会按 Sample 默认值补上，但默认值不一定适合 KVM。")
        lines.append("These keys are missing from this repo's `config.plist`. The packager will fill Sample defaults, which may be wrong for KVM.")
        lines.append("")
        for key in added_keys:
            lines.append(f"- `{key}`")
        lines.append("")
    if removed_keys:
        lines.append("## 当前 config 有、目标 Sample 没有的键 / Keys dropped from Sample")
        lines.append("")
        lines.append("新版 `ocvalidate` 可能拒绝未知键。逐个确认是我们故意保留的，还是应该删掉。")
        lines.append("A newer `ocvalidate` may reject unknown keys. Confirm each one is intentional.")
        lines.append("")
        for key in removed_keys:
            lines.append(f"- `{key}`")
        lines.append("")

    if sections:
        lines.append("## 官方 Changelog 摘录 / Official changelog excerpt")
        lines.append("")
        for ver, body in sections:
            kvm_lines, other = highlight(body)
            lines.append(f"### v{ver}")
            lines.append("")
            if kvm_lines:
                lines.append("**[KVM] 与虚拟机/引导可能相关 / possibly relevant to VMs:**")
                lines.append("")
                for item in kvm_lines:
                    lines.append(f"- **[KVM]** {item}")
                lines.append("")
            if other:
                lines.append("其他变更 / other changes:")
                lines.append("")
                for item in other:
                    lines.append(f"- {item}")
                lines.append("")
    elif pinned != target:
        lines.append("## 警告 / Warning")
        lines.append("")
        lines.append(f"没有从 Changelog 里解析出 `{pinned}` 到 `{target}` 的章节，请手工打开官方 Changelog。")
        lines.append(f"No changelog sections were parsed between `{pinned}` and `{target}`. Read the official file by hand.")
        lines.append("")

    lines.append("## 参考 / References")
    lines.append("")
    lines.append(f"- https://github.com/acidanthera/OpenCorePkg/releases/tag/{target}")
    lines.append("- https://dortania.github.io/OpenCore-Install-Guide/differences.html")
    lines.append("- `scripts/kvm-compat.json`")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="from_version", help="Pinned OpenCore version (default: scripts/component-versions.env)")
    parser.add_argument("--to", dest="to_version", default="latest", help="Target OpenCore tag or latest")
    parser.add_argument("--config", type=Path, default=ROOT / "EFI" / "OC" / "config.plist")
    parser.add_argument("--sample", type=Path, help="Target Docs/Sample.plist (otherwise downloaded)")
    parser.add_argument("--changelog", type=Path, help="Target Docs/Changelog.md (otherwise downloaded)")
    parser.add_argument("--output", type=Path, help="Write markdown here (also printed)")
    args = parser.parse_args()

    pinned = args.from_version or read_pin(VERSIONS_FILE)
    target = args.to_version
    if target == "latest":
        target = latest_tag("acidanthera/OpenCorePkg")
        print(f"latest OpenCore release is {target}", file=sys.stderr)

    if version_key(target) < version_key(pinned):
        raise SystemExit(f"refusing downgrade {pinned} -> {target}")

    if args.changelog:
        changelog = args.changelog.read_text(encoding="utf-8", errors="replace")
    else:
        changelog = fetch_text(
            f"https://raw.githubusercontent.com/acidanthera/OpenCorePkg/{target}/Docs/Changelog.md"
        )
    sections = relevant_sections(split_changelog(changelog), pinned, target)

    added: list[str] = []
    removed: list[str] = []
    if args.config.exists():
        current = load_plist_any(args.config, None)
        if args.sample:
            sample = load_plist_any(args.sample, None)
        else:
            sample = load_plist_any(
                None,
                fetch_bytes(
                    f"https://raw.githubusercontent.com/acidanthera/OpenCorePkg/{target}/Docs/Sample.plist"
                ),
            )
        current_keys = schema_keys(current)
        sample_keys = schema_keys(sample)
        added = sorted(sample_keys - current_keys)
        removed = sorted(current_keys - sample_keys)

    text = render(pinned, target, sections, added, removed)
    print(text)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
        print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
