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
CONTRACT_FILE = ROOT / "scripts" / "kvm-compat.json"
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


def load_contract(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def locked_paths(contract: dict[str, Any]) -> set[str]:
    locked = {"/".join(item["path"]) for item in contract.get("settings", [])}
    for pci in contract.get("device_properties", {}):
        locked.add(f"DeviceProperties/Add/{pci}")
    return locked


def ignored_paths(contract: dict[str, Any]) -> set[str]:
    review = contract.get("review", {})
    return {"/".join(path) for path in review.get("ignore_paths", [])}


def hint_for(contract: dict[str, Any], label: str) -> dict[str, str]:
    hints = contract.get("review", {}).get("hints", {})
    item = hints.get(label, {})
    return {"en": item.get("why_en", ""), "zh": item.get("why_zh", "")}


def format_value(value: Any) -> str:
    if value is None:
        return "—"
    if isinstance(value, (bytes, bytearray)):
        return f"hex:{bytes(value).hex() or '(empty)'}"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, dict):
        return f"dict({len(value)})"
    if isinstance(value, list):
        return f"array({len(value)})"
    return repr(value)


def walk_delta(ours: Any, sample: Any, path: tuple[str, ...] = ()) -> list[tuple[str, tuple[str, ...], Any, Any]]:
    rows: list[tuple[str, tuple[str, ...], Any, Any]] = []
    if path in SKIP_CHILD_FILL:
        return rows
    if isinstance(ours, dict) and isinstance(sample, dict):
        keys = set(ours) | set(sample)
        for key in sorted(keys, key=str):
            if isinstance(key, str) and key.startswith("#"):
                continue
            child = path + (str(key),)
            if key not in ours:
                rows.append(("NEW", child, None, sample[key]))
            elif key not in sample:
                rows.append(("GONE", child, ours[key], None))
            else:
                rows.extend(walk_delta(ours[key], sample[key], child))
        return rows
    if isinstance(ours, list) or isinstance(sample, list):
        return rows
    if ours != sample:
        rows.append(("DIFF", path, ours, sample))
    return rows


def classify_row(
    kind: str,
    label: str,
    locked: set[str],
    ignored: set[str],
) -> str:
    if label in ignored or any(label.startswith(f"{item}/") for item in ignored):
        return "ignore"
    if kind == "NEW":
        return "new"
    if kind == "GONE":
        return "gone"
    if label in locked:
        return "locked"
    return "candidate"


def collect_policy_delta(
    ours: dict[str, Any],
    sample: dict[str, Any],
    contract: dict[str, Any],
) -> dict[str, list[dict[str, Any]]]:
    locked = locked_paths(contract)
    ignored = ignored_paths(contract)
    grouped = {"new": [], "gone": [], "locked": [], "candidate": [], "ignore": []}
    for kind, path, ours_value, sample_value in walk_delta(ours, sample):
        label = "/".join(path)
        klass = classify_row(kind, label, locked, ignored)
        hint = hint_for(contract, label)
        grouped[klass].append(
            {
                "kind": kind,
                "path": label,
                "ours": ours_value,
                "sample": sample_value,
                "hint_en": hint["en"],
                "hint_zh": hint["zh"],
            }
        )
    return grouped


def render_value_table(title_zh: str, title_en: str, intro_zh: str, intro_en: str, rows: list[dict[str, Any]]) -> list[str]:
    if not rows:
        return []
    lines = [
        f"## {title_zh} / {title_en}",
        "",
        intro_zh,
        intro_en,
        "",
        "| Key | Ours | Sample | Note |",
        "| --- | --- | --- | --- |",
    ]
    for row in rows:
        note = row["hint_zh"] or row["hint_en"] or ""
        lines.append(
            f"| `{row['path']}` | `{format_value(row['ours'])}` | `{format_value(row['sample'])}` | {note} |"
        )
    lines.append("")
    return lines


def render(
    pinned: str,
    target: str,
    sections: list[tuple[str, str]],
    added_keys: list[str],
    removed_keys: list[str],
    policy: dict[str, list[dict[str, Any]]] | None = None,
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
        lines.append("- 禁止整份覆盖 `Sample.plist`。新键要单独决定 KVM 默认值；契约锁死的旧键不要跟 Sample；未锁死但值变了的键才是性能/修 bug 候选。")
        lines.append("- Never replace `config.plist` with `Sample.plist`. Decide new keys one by one; keep locked KVM values; only unlocked value changes are candidates for performance/bugfix adoptions.")
    lines.append("")
    if policy:
        n_new = len(policy.get("new", []))
        n_cand = len(policy.get("candidate", []))
        n_lock = len(policy.get("locked", []))
        lines.append(f"- 本轮对照 Sample：新键 **{n_new}**，可评估的旧键新值 **{n_cand}**，契约锁死且与 Sample 不同 **{n_lock}**。")
        lines.append(f"- Versus Sample this round: **{n_new}** new keys, **{n_cand}** unlocked value changes, **{n_lock}** locked diffs (keep ours).")
        if pinned != target and (n_new or n_cand):
            lines.append("- 有新键或候选值时，必须先改 `EFI/OC/config.plist` 并测虚拟机，不能只换 `OpenCore.efi`。")
            lines.append("- New keys or candidate values mean you must edit `EFI/OC/config.plist` and test the VM. Do not only swap `OpenCore.efi`.")
        elif pinned == target and n_cand:
            lines.append("- 与 Sample 的候选差异是长期存在的，下次升 core 时再逐条评估，不必为了发同一版去改。")
            lines.append("- Unlocked Sample drift is expected at this pin. Re-evaluate it the next time the core version actually moves.")
    lines.append("")
    lines.append("## 升级前必做 / Required before publish")
    lines.append("")
    lines.append("1. 读完本文里标了 **[KVM]** 的条目，并打开官方 `Docs/Changelog.md` / `Docs/Differences.pdf`。")
    lines.append("   Read every **[KVM]** line below and the official changelog / Differences.pdf.")
    lines.append("2. 处理三类 plist 差异：新键决定默认值；锁定键保持契约；候选键评估是否采纳官方新推荐值。")
    lines.append("   Handle three plist classes: decide new keys, keep locked contract values, evaluate unlocked Sample value changes.")
    lines.append("3. `python3 scripts/check-kvm-compat.py EFI/OC/config.plist` 必须通过。")
    lines.append("   The KVM contract check must pass.")
    lines.append("4. 用目标版本自带的 `ocvalidate` 校验 `EFI/OC/config.plist`。")
    lines.append("   Validate with the **target** `ocvalidate`, not an older copy.")
    lines.append("5. 先打 **draft** Release，虚拟机里保留旧的 OpenCore 盘作为回滚。")
    lines.append("   Publish a **draft** first and keep the previous OpenCore disk attached for rollback.")
    lines.append("6. 至少验证：选择菜单出现、能进已安装的 macOS、能进恢复/安装器（如适用）。")
    lines.append("   Smoke-test: picker shows, installed macOS boots, Recovery/installer still opens if you use them.")
    lines.append("7. 通过后再改 `scripts/component-versions.env` 并正式发版。")
    lines.append("   Only then bump `scripts/component-versions.env` and publish.")
    lines.append("")

    if policy:
        lines.extend(
            render_value_table(
                "必须决策的新参数",
                "New keys that need a KVM decision",
                "这些键仓库里还没有。打包时会暂用 Sample 默认值，但默认值可能不适合 QEMU。采纳后写进 `config.plist`；若不能跟 Sample，把安全值锁进 `kvm-compat.json`。",
                "These keys are missing from the repo. The packager temporarily fills Sample defaults, which may be wrong for QEMU. Commit the chosen value; if Sample is unsafe, lock our value in `kvm-compat.json`.",
                policy.get("new", []),
            )
        )
        lines.extend(
            render_value_table(
                "可评估的旧参数新推荐值",
                "Unlocked keys whose Sample value changed",
                "我们已有这些键，但官方 Sample 推荐值不同。这里才是性能提升或修已有问题的候选。不要自动采用；对照 Changelog，改完必须测虚拟机。",
                "We already have these keys, but Sample now recommends something else. These are the performance/bugfix candidates. Do not auto-adopt; read the changelog and test the VM after any change.",
                policy.get("candidate", []),
            )
        )
        lines.extend(
            render_value_table(
                "契约锁死（即使 Sample 变了也不跟）",
                "Locked contract values (do not follow Sample)",
                "这些值是 QEMU/KVM 专用选择。Sample 面向真机，跟了会无法启动或失去本镜像的行为。只有有意改变 KVM 策略时才改契约。",
                "These are QEMU/KVM-specific. Sample targets real Macs; following it can brick the guest. Change `kvm-compat.json` only when the KVM policy itself changes.",
                policy.get("locked", []),
            )
        )
        if policy.get("gone"):
            lines.extend(
                render_value_table(
                    "目标 Sample 已删除的键",
                    "Keys dropped from Sample",
                    "新版 `ocvalidate` 可能拒绝未知键。确认是本镜像故意保留，还是应该删掉。",
                    "A newer `ocvalidate` may reject unknown keys. Keep only if this image still needs them.",
                    policy.get("gone", []),
                )
            )
        ignored = policy.get("ignore", [])
        if ignored:
            lines.append(f"已忽略 {len(ignored)} 个机身/序列号类差异（MLB、ROM、Serial、UUID），不参与性能评估。")
            lines.append(f"Ignored {len(ignored)} identity fields (MLB, ROM, serial, UUID); they are not performance candidates.")
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
    policy: dict[str, list[dict[str, Any]]] | None = None
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
        policy = collect_policy_delta(current, sample, load_contract(CONTRACT_FILE))

    text = render(pinned, target, sections, added, removed, policy)
    print(text)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
        print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
