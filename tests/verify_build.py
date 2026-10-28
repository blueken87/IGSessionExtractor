#!/usr/bin/env python3
"""Verify the Debian payload contains the tweak and the Instagram filter."""
import io
import plistlib
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    packages = list((ROOT / "packages").glob("*.deb"))
    if not packages:
        print("missing .deb")
        return 1

    package = packages[0]
    members = subprocess.check_output(["ar", "t", str(package)], text=True).splitlines()
    data_name = next(name for name in members if name.startswith("data.tar"))
    payload = subprocess.check_output(["ar", "p", str(package), data_name])

    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:*") as archive:
        names = {item.name.removeprefix("./"): item for item in archive.getmembers()}
        base = None
        for candidate in (
            "var/jb/Library/MobileSubstrate/DynamicLibraries/IGSessionExtractor",
            "Library/MobileSubstrate/DynamicLibraries/IGSessionExtractor",
        ):
            if candidate + ".dylib" in names:
                base = candidate
                break
        if not base:
            print("missing dylib")
            return 1
        if names[base + ".dylib"].size == 0:
            print("empty dylib")
            return 1
        if base + ".plist" not in names:
            print("missing filter plist")
            return 1
        data = plistlib.loads(archive.extractfile(names[base + ".plist"]).read())
        bundles = data.get("Filter", {}).get("Bundles", [])
        if "com.burbn.instagram" not in bundles:
            print(f"unexpected filter bundles: {bundles}")
            return 1

    print(f"PASS: {package.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
