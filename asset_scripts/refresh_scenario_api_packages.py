#!/usr/bin/env python3
"""Refresh bundle integrity after the built-in Scenario API catalog changes."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def refresh_package(package_root: Path, catalog_hash: str, check: bool) -> bool:
    scripts_path = package_root / "remake" / "scripts.json"
    manifest_path = package_root / "campaign.json"
    if not scripts_path.is_file() or not manifest_path.is_file():
        raise ValueError(f"Scenario package is incomplete: {package_root}")

    scripts = json.loads(scripts_path.read_text(encoding="utf-8"))
    scripts["capabilityCatalogHash"] = catalog_hash
    scripts_bytes = canonical_bytes(scripts)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    capabilities = manifest.get("capabilities", {})
    script_tiers = capabilities.get("scriptExecutionTiers", [])
    if not isinstance(script_tiers, list) or any(
        not isinstance(tier, str) for tier in script_tiers
    ):
        raise ValueError(
            f"Scenario package has invalid script execution tiers: {package_root}"
        )
    unsupported_tiers = sorted(set(script_tiers) - {"safe", "sandboxed"})
    if unsupported_tiers:
        raise ValueError(
            f"Scenario package advertises unsupported script execution tiers "
            f"{unsupported_tiers}: {package_root}"
        )
    integrity = manifest.get("integrity")
    if not isinstance(integrity, dict) or not isinstance(integrity.get("files"), dict):
        raise ValueError(f"Scenario package has no integrity file map: {package_root}")
    integrity["files"]["remake/scripts.json"] = {
        "bytes": len(scripts_bytes),
        "sha256": sha256(scripts_bytes),
    }
    integrity.pop("packageHash", None)
    integrity["packageHash"] = sha256(canonical_bytes(manifest))
    manifest_bytes = canonical_bytes(manifest)
    provenance_path = package_root.with_name(
        f"{package_root.name}.provenance.json"
    )
    provenance_bytes: bytes | None = None
    if provenance_path.is_file():
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        file_records = provenance.get("files")
        if not isinstance(file_records, list):
            raise ValueError(
                f"Scenario fixture provenance has no file list: {provenance_path}"
            )
        pending_payloads = {
            "campaign.json": manifest_bytes,
            "remake/scripts.json": scripts_bytes,
        }
        for record in file_records:
            if not isinstance(record, dict):
                raise ValueError(
                    f"Scenario fixture provenance has an invalid file record: "
                    f"{provenance_path}"
                )
            relative_path = record.get("path")
            if not isinstance(relative_path, str):
                raise ValueError(
                    f"Scenario fixture provenance has an invalid file path: "
                    f"{provenance_path}"
                )
            path = Path(relative_path)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(
                    f"Scenario fixture provenance escapes the package root: "
                    f"{relative_path}"
                )
            payload = pending_payloads.get(relative_path)
            if payload is None:
                package_file = package_root.joinpath(*path.parts)
                if not package_file.is_file():
                    raise ValueError(
                        f"Scenario fixture provenance references a missing file "
                        f"{relative_path}: {provenance_path}"
                    )
                payload = package_file.read_bytes()
            record["bytes"] = len(payload)
            record["sha256"] = sha256(payload)
        recorded_paths = {
            record.get("path")
            for record in file_records
            if isinstance(record, dict)
        }
        missing = set(pending_payloads) - recorded_paths
        if missing:
            raise ValueError(
                f"Scenario fixture provenance is missing refreshed files "
                f"{sorted(missing)}: {provenance_path}"
            )
        provenance_bytes = canonical_bytes(provenance)

    changed = (
        scripts_path.read_bytes() != scripts_bytes
        or manifest_path.read_bytes() != manifest_bytes
        or (
            provenance_bytes is not None
            and provenance_path.read_bytes() != provenance_bytes
        )
    )
    if changed and not check:
        scripts_path.write_bytes(scripts_bytes)
        manifest_path.write_bytes(manifest_bytes)
        if provenance_bytes is not None:
            provenance_path.write_bytes(provenance_bytes)
    return changed


def package_roots(root: Path) -> list[Path]:
    roots = {
        scripts_path.parent.parent
        for scripts_path in root.rglob("scripts.json")
        if scripts_path.parent.name == "remake"
        and (scripts_path.parent.parent / "campaign.json").is_file()
    }
    return sorted(roots)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("src/Data/remake-scenario-capabilities.v2.json"),
    )
    parser.add_argument("--root", type=Path, action="append", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    catalog_hash = sha256(canonical_bytes(catalog))
    packages = sorted({
        package
        for root in args.root
        for package in package_roots(root)
    })
    if not packages:
        raise ValueError("No scenario packages were found")

    changed = [
        package
        for package in packages
        if refresh_package(package, catalog_hash, args.check)
    ]
    verb = "need refresh" if args.check else "refreshed"
    for package in changed:
        print(f"{verb}: {package.as_posix()}")
    if args.check and changed:
        return 1
    print(
        f"Scenario API package integrity is current for {len(packages)} package(s); "
        f"catalog {catalog_hash}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
