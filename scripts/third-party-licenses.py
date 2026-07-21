#!/usr/bin/env python3
"""Collect the locked Rust dependency license texts for binary releases."""

import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} OUTPUT", file=sys.stderr)
        return 2

    metadata = json.loads(
        subprocess.check_output(
            [
                "cargo",
                "metadata",
                "--locked",
                "--format-version",
                "1",
                "--manifest-path",
                "ui/linux/Cargo.toml",
            ],
            text=True,
        )
    )
    packages = sorted(
        (package for package in metadata["packages"] if package["name"] != "sayall-hud"),
        key=lambda package: (package["name"], package["version"]),
    )

    license_files_by_package = {}
    templates = {}
    for package in packages:
        crate_dir = Path(package["manifest_path"]).parent
        license_files = sorted(
            {
                path
                for pattern in ("LICENSE*", "COPYING*", "UNLICENSE*")
                for path in crate_dir.glob(pattern)
                if path.is_file()
            }
        )
        license_files_by_package[(package["name"], package["version"])] = license_files
        for license_file in license_files:
            if license_file.name in ("LICENSE-MIT", "LICENSE-APACHE"):
                templates.setdefault(license_file.name, license_file)

    output = Path(sys.argv[1])
    with output.open("w", encoding="utf-8") as notices:
        notices.write("Rust dependencies included in sayall-hud\n")
        notices.write("Generated from the locked Cargo dependency graph.\n")
        for package in packages:
            license_files = license_files_by_package[
                (package["name"], package["version"])
            ]
            if not license_files:
                declared = package.get("license") or ""
                template_name = (
                    "LICENSE-MIT" if "MIT" in declared else "LICENSE-APACHE"
                )
                template = templates.get(template_name)
                if template is None or not (
                    "MIT" in declared or "Apache-2.0" in declared
                ):
                    raise RuntimeError(
                        f"no license text found for {package['name']} "
                        f"{package['version']} ({declared or 'unspecified'})"
                    )
                license_files = [template]

            notices.write(
                f"\n{'=' * 72}\n"
                f"{package['name']} {package['version']}\n"
                f"Declared license: {package.get('license') or 'not specified'}\n"
            )
            for license_file in license_files:
                notices.write(f"\n--- {license_file.name} ---\n")
                notices.write(license_file.read_text(encoding="utf-8", errors="replace"))
                notices.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
