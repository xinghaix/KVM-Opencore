#!/usr/bin/env python3
"""Fail if config.plist drifts from the KVM/QEMU compatibility contract."""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
DEFAULT_CONTRACT = ROOT / "kvm-compat.json"


def load_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        data = plistlib.load(handle)
    if not isinstance(data, dict):
        raise SystemExit(f"{path} is not a dictionary plist")
    return data


def walk(cfg: dict[str, Any], path: list[str]) -> Any:
    node: Any = cfg
    for key in path:
        if not isinstance(node, dict) or key not in node:
            raise KeyError("/".join(path))
        node = node[key]
    return node


def hex_of(value: Any) -> str:
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).hex()
    raise TypeError(f"expected data, got {type(value).__name__}")


def find_kext(cfg: dict[str, Any], bundle: str) -> dict[str, Any] | None:
    entries = cfg.get("Kernel", {}).get("Add", [])
    if not isinstance(entries, list):
        return None
    for item in entries:
        if isinstance(item, dict) and item.get("BundlePath") == bundle:
            return item
    return None


def find_driver(cfg: dict[str, Any], name: str) -> dict[str, Any] | None:
    entries = cfg.get("UEFI", {}).get("Drivers", [])
    if not isinstance(entries, list):
        return None
    for item in entries:
        if isinstance(item, dict) and item.get("Path") == name:
            return item
    return None


def find_acpi(cfg: dict[str, Any], name: str) -> dict[str, Any] | None:
    entries = cfg.get("ACPI", {}).get("Add", [])
    if not isinstance(entries, list):
        return None
    for item in entries:
        if isinstance(item, dict) and item.get("Path") == name:
            return item
    return None


def report(ok: bool, title: str, why_en: str = "", why_zh: str = "") -> None:
    mark = "OK  " if ok else "FAIL"
    print(f"{mark} {title}")
    if why_en:
        print(f"     EN: {why_en}")
    if why_zh:
        print(f"     ZH: {why_zh}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="Path to EFI/OC/config.plist")
    parser.add_argument(
        "--contract",
        type=Path,
        default=DEFAULT_CONTRACT,
        help="KVM compatibility contract (default: scripts/kvm-compat.json)",
    )
    parser.add_argument(
        "--efi-root",
        type=Path,
        help="Optional EFI root used to check that ACPI/kext files exist on disk",
    )
    args = parser.parse_args()

    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    cfg = load_plist(args.config)
    failures = 0

    print("=== KVM/QEMU compatibility contract ===")
    print(f"config:   {args.config}")
    print(f"contract: {args.contract}")
    print()

    for item in contract.get("settings", []):
        path = item["path"]
        label = "/".join(path)
        why_en = item.get("why_en", "")
        why_zh = item.get("why_zh", "")
        try:
            actual = walk(cfg, path)
        except KeyError:
            report(False, f"{label} is missing", why_en, why_zh)
            failures += 1
            continue
        if "equals_hex" in item:
            try:
                got = hex_of(actual)
            except TypeError as exc:
                report(False, f"{label}: {exc}", why_en, why_zh)
                failures += 1
                continue
            expect = item["equals_hex"].lower()
            ok = got == expect
            report(ok, f"{label} = {got} (want {expect})", why_en, why_zh)
            failures += int(not ok)
            continue
        expect = item["equals"]
        ok = actual == expect
        report(ok, f"{label} = {actual!r} (want {expect!r})", why_en, why_zh)
        failures += int(not ok)

    print()
    print("=== DeviceProperties ===")
    for pci, spec in contract.get("device_properties", {}).items():
        node = cfg.get("DeviceProperties", {}).get("Add", {}).get(pci)
        why_en = spec.get("why_en", "")
        why_zh = spec.get("why_zh", "")
        if not isinstance(node, dict):
            report(False, f"{pci} is missing", why_en, why_zh)
            failures += 1
            continue
        for key in ("compatible", "name"):
            if key in spec:
                ok = node.get(key) == spec[key]
                report(ok, f"{pci}/{key} = {node.get(key)!r} (want {spec[key]!r})", why_en, why_zh)
                failures += int(not ok)
        if "device-id_hex" in spec:
            try:
                got = hex_of(node.get("device-id"))
            except TypeError:
                got = ""
            expect = spec["device-id_hex"].lower()
            ok = got == expect
            report(ok, f"{pci}/device-id = {got} (want {expect})", why_en, why_zh)
            failures += int(not ok)

    print()
    print("=== Kexts ===")
    for spec in contract.get("kexts", []):
        bundle = spec["bundle"]
        why_en = spec.get("why_en", "")
        why_zh = spec.get("why_zh", "")
        entry = find_kext(cfg, bundle)
        if entry is None:
            report(False, f"{bundle} is not in Kernel/Add", why_en, why_zh)
            failures += 1
            continue
        if "enabled" in spec:
            ok = bool(entry.get("Enabled")) is bool(spec["enabled"])
            report(
                ok,
                f"{bundle} Enabled={entry.get('Enabled')!r} (want {spec['enabled']!r})",
                why_en,
                why_zh,
            )
            failures += int(not ok)
        if spec.get("min") is not None:
            ok = entry.get("MinKernel") == spec["min"]
            report(ok, f"{bundle} MinKernel={entry.get('MinKernel')!r} (want {spec['min']!r})", why_en, why_zh)
            failures += int(not ok)
        if spec.get("max") is not None:
            ok = entry.get("MaxKernel") == spec["max"]
            report(ok, f"{bundle} MaxKernel={entry.get('MaxKernel')!r} (want {spec['max']!r})", why_en, why_zh)
            failures += int(not ok)
        if args.efi_root and spec.get("enabled", True):
            info = args.efi_root / "OC" / "Kexts" / bundle / "Contents" / "Info.plist"
            ok = info.is_file()
            report(ok, f"file {info.relative_to(args.efi_root)}")
            failures += int(not ok)

    print()
    print("=== Drivers / ACPI ===")
    for name in contract.get("drivers", []):
        entry = find_driver(cfg, name)
        ok = bool(entry and entry.get("Enabled"))
        report(ok, f"UEFI/Drivers {name} Enabled")
        failures += int(not ok)
        if args.efi_root:
            path = args.efi_root / "OC" / "Drivers" / name
            exists = path.is_file()
            report(exists, f"file OC/Drivers/{name}")
            failures += int(not exists)
    for name in contract.get("acpi", []):
        entry = find_acpi(cfg, name)
        ok = bool(entry and entry.get("Enabled"))
        report(ok, f"ACPI/Add {name} Enabled")
        failures += int(not ok)
        if args.efi_root:
            path = args.efi_root / "OC" / "ACPI" / name
            exists = path.is_file()
            report(exists, f"file OC/ACPI/{name}")
            failures += int(not exists)

    print()
    if failures:
        print(f"{failures} KVM compatibility check(s) failed.")
        print("Do not publish this image. See README.md / README.zh-CN.md upgrade process.")
        return 1
    print("KVM compatibility contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
