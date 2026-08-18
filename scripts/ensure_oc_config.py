#!/usr/bin/env python3
"""Make a KVM-Opencore config.plist valid for a given OpenCore Sample.plist.

Only fills missing schema keys. Never copies Sample hardware entries
(DeviceProperties / NVRAM variables / array contents).
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path
from typing import Any


# Dicts whose children are machine-specific data, not OpenCore schema.
SKIP_CHILD_FILL = {
    ("DeviceProperties", "Add"),
    ("DeviceProperties", "Delete"),
    ("NVRAM", "Add"),
    ("NVRAM", "Delete"),
    ("NVRAM", "LegacySchema"),
}

CSR_KEY_PATH = (
    "NVRAM",
    "Add",
    "7C436110-AB2A-4BBB-A880-FE41995C9F82",
    "csr-active-config",
)


def load_plist(path: Path) -> Any:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def write_plist(path: Path, data: Any) -> None:
    with path.open("wb") as handle:
        plistlib.dump(data, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def skip_children(path: tuple[str, ...]) -> bool:
    return path in SKIP_CHILD_FILL or (len(path) >= 2 and path[:2] in SKIP_CHILD_FILL)


def fill_missing(dst: Any, src: Any, path: tuple[str, ...] = ()) -> list[str]:
    added: list[str] = []
    if not isinstance(dst, dict) or not isinstance(src, dict):
        return added
    if skip_children(path):
        return added
    for key, value in src.items():
        if isinstance(key, str) and key.startswith("#"):
            continue
        child = path + (str(key),)
        if key not in dst:
            dst[key] = value
            added.append("/".join(child))
            continue
        added.extend(fill_missing(dst[key], value, child))
    return added


def pad_csr_active_config(cfg: dict[str, Any]) -> str | None:
    node: Any = cfg
    for key in CSR_KEY_PATH[:-1]:
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    name = CSR_KEY_PATH[-1]
    value = node.get(name)
    if not isinstance(value, (bytes, bytearray)):
        return None
    if len(value) >= 4:
        return None
    padded = bytes(value).ljust(4, b"\x00")
    node[name] = padded
    return padded.hex()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="Path to EFI/OC/config.plist")
    parser.add_argument(
        "--sample",
        type=Path,
        help="OpenCore Docs/Sample.plist used to fill missing schema keys",
    )
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="Rewrite config in place (default if --output is omitted)",
    )
    parser.add_argument("--output", type=Path, help="Write result to this path")
    args = parser.parse_args()

    cfg = load_plist(args.config)
    added: list[str] = []
    if args.sample:
        added = fill_missing(cfg, load_plist(args.sample))
        for item in added:
            print(f"added missing key: {item}", file=sys.stderr)
    csr = pad_csr_active_config(cfg)
    if csr:
        print(f"padded csr-active-config to 4 bytes: {csr}", file=sys.stderr)

    dest = args.output or args.config
    if dest != args.config or args.in_place or args.output is None:
        write_plist(dest, cfg)
        print(f"wrote {dest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
