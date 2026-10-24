#!/usr/bin/env python3
"""Bind a Meetings app bundle to its exact source inputs and edition."""
from __future__ import annotations

import hashlib
import json
import pathlib
import plistlib
import subprocess
from datetime import datetime, timezone
from typing import Optional


APP_ROOT = pathlib.Path(__file__).resolve().parent.parent
NATIVE = pathlib.Path("native")
EDITION = {
    "baseline": ("Meetings Replica", "uk.pipreps.meetings.replica", "0.1.0-alpha.1", ["-DPIP_EDITION", "-DPIP_NEUTRAL", "-DMEETINGS_REPLICA"]),
    "baseline-enhanced": ("Meetings Baseline Enhanced", "uk.pipreps.meetings.neutral.enhanced", "0.1.0-alpha.2", ["-DPIP_EDITION", "-DPIP_NEUTRAL", "-DMEETINGS_ENHANCEMENTS"]),
    "pip": ("Pip Meetings", "uk.pipreps.meetings", "0.1.0-alpha.1", ["-DPIP_EDITION"]),
    "pip-enhanced": ("Pip Meetings Enhanced", "uk.pipreps.meetings.enhanced", "0.1.0-alpha.2", ["-DPIP_EDITION", "-DMEETINGS_ENHANCEMENTS"]),
    "upstream": ("Meeting Transcriber Upstream", "uk.pipreps.meetings.baseline", "0.8.1-baseline.1", []),
}
RESOURCE_MANIFEST = "MeetingsBuildManifest.json"
RESOURCE_RECEIPT = "MeetingsBuildReceipt.json"


class IntegrityError(ValueError):
    pass


def distribution_config(root: pathlib.Path) -> dict:
    path = root / "distribution.json"
    if not path.exists() and not path.is_symlink():
        return {"default_edition": "pip", "editions": ["baseline", "baseline-enhanced", "pip", "pip-enhanced"]}
    if path.is_symlink() or not path.is_file():
        raise IntegrityError("distribution.json must be a regular non-symlink file")
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IntegrityError(f"distribution.json is unreadable or invalid: {error}") from error
    if not isinstance(config, dict) or set(config) != {"default_edition", "editions"}:
        raise IntegrityError("distribution.json must contain only default_edition and editions")
    editions = config["editions"]
    if (not isinstance(editions, list) or not editions or
            any(not isinstance(item, str) or item not in EDITION for item in editions) or
            len(set(editions)) != len(editions)):
        raise IntegrityError("distribution.json editions must be a unique non-empty list of supported variants")
    if set(editions) not in ({"baseline"}, {"baseline-enhanced", "pip", "pip-enhanced"}):
        raise IntegrityError("distribution.json must define the neutral baseline or the three Pip export variants")
    default = config["default_edition"]
    if not isinstance(default, str) or default not in editions:
        raise IntegrityError("distribution.json default_edition must be included in editions")
    return config


def check_distribution_edition(root: pathlib.Path, edition: str) -> None:
    if edition == "upstream" and not (root / "distribution.json").exists():
        return
    config = distribution_config(root)
    if edition not in config["editions"]:
        raise IntegrityError(f"edition {edition!r} is not included in this app export")


def _canonical(payload: object) -> bytes:
    return (json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _selected_files(root: pathlib.Path) -> list[pathlib.Path]:
    fixed = [
        "scripts/build-native.sh",
        "scripts/test-native.sh",
        "scripts/release_integrity.py",
        "scripts/release-info.py",
        "scripts/test_release_integrity.py",
        "native/VERSION",
        "native/LICENSE",
        "native/THIRD-PARTY-NOTICES.md",
        "native/app/MeetingTranscriber/Package.swift",
        "native/app/MeetingTranscriber/Package.resolved",
        "native/tools/audiotap/Package.swift",
        "native/scripts/fetch-localvqe-model.sh",
        "native/scripts/lib/bundle-licenses.sh",
        "native/scripts/lib/localvqe-resources.sh",
    ]
    files = {pathlib.Path(item) for item in fixed}
    if (root / "distribution.json").exists() or (root / "distribution.json").is_symlink():
        files.add(pathlib.Path("distribution.json"))
    if (root / "distribution.json").exists():
        files.add(pathlib.Path("distribution.json"))
    recursive = (
        "native/app/MeetingTranscriber/Sources",
        "native/app/MeetingTranscriber/Tests",
        "native/app/MeetingTranscriber/Entitlements",
        "native/tools/audiotap/Sources",
        "native/tools/audiotap/Tests",
        "native/licenses",
    )
    for relative_dir in recursive:
        base = root / relative_dir
        if not base.is_dir() or base.is_symlink():
            raise IntegrityError(f"Build input directory is missing or a symlink: {relative_dir}")
        for path in base.rglob("*"):
            if path.is_symlink():
                raise IntegrityError(f"Build input is a symlink: {path.relative_to(root)}")
            if path.is_file():
                files.add(path.relative_to(root))

    for relative in sorted(files, key=lambda item: item.as_posix()):
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise IntegrityError(f"Build input is missing or is a symlink: {relative}")
        for parent in relative.parents:
            if parent == pathlib.Path("."):
                break
            if (root / parent).is_symlink():
                raise IntegrityError(f"Build input has a symlinked parent: {relative}")
    return sorted(files, key=lambda item: item.as_posix())


def source_manifest(root: pathlib.Path) -> dict:
    entries = []
    for relative in _selected_files(root):
        data = (root / relative).read_bytes()
        entries.append({"path": relative.as_posix(), "size": len(data), "sha256": _sha256(data)})
    return {"schema": 1, "files": entries}


def manifest_digest(manifest: dict) -> str:
    return _sha256(_canonical(manifest))


def source_revision(root: pathlib.Path) -> tuple[str, Optional[bool]]:
    try:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=root, check=True, capture_output=True, text=True).stdout
        return revision, bool(dirty.strip())
    except (FileNotFoundError, subprocess.CalledProcessError):
        return "unversioned", None


def resource_inventory(app: pathlib.Path) -> list[dict]:
    resources = app / "Contents/Resources"
    result = []
    for path in sorted(resources.rglob("*")):
        if path.is_symlink():
            raise IntegrityError(f"Bundled resource is a symlink: {path.relative_to(app)}")
        if path.is_file() and path.name not in (RESOURCE_MANIFEST, RESOURCE_RECEIPT):
            data = path.read_bytes()
            result.append({"path": path.relative_to(resources).as_posix(), "size": len(data), "sha256": _sha256(data)})
    return result


def _load_json(path: pathlib.Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise IntegrityError(f"Could not read build metadata: {path}") from error
    if not isinstance(value, dict):
        raise IntegrityError(f"Build metadata is not an object: {path}")
    return value


def write_receipt(root: pathlib.Path, app: pathlib.Path, edition: str, expected_manifest: pathlib.Path, expected_digest: str) -> dict:
    try:
        name, bundle_id, version, flags = EDITION[edition]
    except KeyError as error:
        raise IntegrityError(f"Unknown edition: {edition}") from error
    manifest = _load_json(expected_manifest)
    digest = manifest_digest(manifest)
    current = source_manifest(root)
    if digest != expected_digest or manifest != current:
        raise IntegrityError("Source changed during build; refusing to package")
    executable = app / "Contents/MacOS/MeetingTranscriber"
    if not executable.is_file() or executable.is_symlink():
        raise IntegrityError("Staged executable is missing or is a symlink")
    revision, dirty = source_revision(root)
    receipt = {
        "schema": 1,
        "edition": edition,
        "bundle_name": name,
        "bundle_id": bundle_id,
        "version": version,
        "compiler_flags": flags,
        "source_revision": revision,
        "source_dirty": dirty,
        "source_manifest_sha256": digest,
        "resources": resource_inventory(app),
        "built_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / RESOURCE_MANIFEST).write_bytes(_canonical(manifest))
    (resources / RESOURCE_RECEIPT).write_bytes(_canonical(receipt))
    return receipt


def verify_package(root: pathlib.Path, app: pathlib.Path, edition: str) -> dict:
    try:
        name, bundle_id, version, flags = EDITION[edition]
    except KeyError as error:
        raise IntegrityError(f"Unknown edition: {edition}") from error
    resources = app / "Contents/Resources"
    manifest = _load_json(resources / RESOURCE_MANIFEST)
    receipt = _load_json(resources / RESOURCE_RECEIPT)
    current = source_manifest(root)
    digest = manifest_digest(current)
    revision, dirty = source_revision(root)
    if manifest != current:
        raise IntegrityError(f"Package source inputs are stale for {edition}")
    expected = {
        "schema": 1,
        "edition": edition,
        "bundle_name": name,
        "bundle_id": bundle_id,
        "version": version,
        "compiler_flags": flags,
        "source_manifest_sha256": digest,
        "source_revision": revision,
        "source_dirty": dirty,
        "resources": resource_inventory(app),
    }
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise IntegrityError(f"Build receipt does not match package/source: {edition}")
    executable = app / "Contents/MacOS/MeetingTranscriber"
    if not executable.is_file() or executable.is_symlink():
        raise IntegrityError(f"Package executable is missing: {edition}")
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise IntegrityError(f"Package Info.plist is invalid for {edition}") from error
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleName"), info.get("CFBundleDisplayName")) != (bundle_id, version, name, name):
        raise IntegrityError(f"Package identity/version does not match edition: {edition}")
    return receipt


def cli() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    manifest_parser = sub.add_parser("manifest")
    manifest_parser.add_argument("root", type=pathlib.Path)
    manifest_parser.add_argument("destination", type=pathlib.Path)
    receipt_parser = sub.add_parser("receipt")
    receipt_parser.add_argument("root", type=pathlib.Path)
    receipt_parser.add_argument("app", type=pathlib.Path)
    receipt_parser.add_argument("edition", choices=sorted(EDITION))
    receipt_parser.add_argument("manifest", type=pathlib.Path)
    receipt_parser.add_argument("manifest_sha256")
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("root", type=pathlib.Path)
    verify_parser.add_argument("app", type=pathlib.Path)
    verify_parser.add_argument("edition", choices=sorted(EDITION))
    default_parser = sub.add_parser("distribution-default")
    default_parser.add_argument("root", type=pathlib.Path)
    list_parser = sub.add_parser("distribution-list")
    list_parser.add_argument("root", type=pathlib.Path)
    check_parser = sub.add_parser("distribution-check")
    check_parser.add_argument("root", type=pathlib.Path)
    check_parser.add_argument("edition")
    args = parser.parse_args()
    try:
        if args.command == "manifest":
            manifest = source_manifest(args.root.resolve())
            args.destination.parent.mkdir(parents=True, exist_ok=True)
            args.destination.write_bytes(_canonical(manifest))
            print(manifest_digest(manifest))
        elif args.command == "receipt":
            receipt = write_receipt(args.root.resolve(), args.app.resolve(), args.edition, args.manifest.resolve(), args.manifest_sha256)
            print(receipt["source_manifest_sha256"])
        elif args.command == "verify":
            print(json.dumps(verify_package(args.root.resolve(), args.app.resolve(), args.edition), sort_keys=True))
        elif args.command == "distribution-default":
            print(distribution_config(args.root.resolve())["default_edition"])
        elif args.command == "distribution-list":
            print(" ".join(distribution_config(args.root.resolve())["editions"]))
        else:
            check_distribution_edition(args.root.resolve(), args.edition)
    except (IntegrityError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release integrity check failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(cli())
