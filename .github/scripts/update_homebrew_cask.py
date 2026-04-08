#!/usr/bin/env python3

import argparse
import pathlib
import re
import sys


VERSION_RE = re.compile(r'version "[^"]+"')
SHA_RE = re.compile(r"sha256 .+")
ASSET_RE = re.compile(r"releases/assets/\d+")


def replace_once(pattern: re.Pattern[str], text: str, replacement: str, label: str) -> str:
    updated, count = pattern.subn(replacement, text, count=1)
    if count != 1:
        raise ValueError(f"Could not update {label} in cask file")
    return updated


def update_cask_text(text: str, version: str, asset_id: str, sha256: str) -> str:
    updated = replace_once(VERSION_RE, text, f'version "{version}"', "version")
    updated = replace_once(ASSET_RE, updated, f"releases/assets/{asset_id}", "asset ID")

    sha_line = "sha256 :no_check" if sha256 == ":no_check" else f'sha256 "{sha256}"'
    updated = replace_once(SHA_RE, updated, sha_line, "sha256")
    return updated


def main() -> int:
    parser = argparse.ArgumentParser(description="Update a Homebrew cask file for a new Trident release asset.")
    parser.add_argument("--cask-file", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--asset-id", required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()

    cask_path = pathlib.Path(args.cask_file)
    original = cask_path.read_text()
    updated = update_cask_text(
        original,
        version=args.version,
        asset_id=args.asset_id,
        sha256=args.sha256,
    )

    if updated != original:
        cask_path.write_text(updated)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
