#!/usr/bin/env python3
"""Verify a signed Meetings bundle and emit external, post-sign release facts."""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from release_integrity import IntegrityError, verify_package  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("edition")
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--reported-bundle-path", type=pathlib.Path)
    args = parser.parse_args()
    try:
        root, app = args.root.resolve(), args.app.resolve()
        receipt = verify_package(root, app, args.edition)
        executable = app / "Contents/MacOS/MeetingTranscriber"
        signature = subprocess.run(
            ["codesign", "--verify", "--strict", "--verbose=2", str(app)],
            check=True, capture_output=True, text=True,
        )
        details = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)], check=True, capture_output=True, text=True)
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        raw_signature_details = (details.stderr or details.stdout).strip().splitlines()
        safe_signature_details = {}
        for line in raw_signature_details:
            if line.startswith("CodeDirectory "):
                safe_signature_details["CodeDirectory"] = line.removeprefix("CodeDirectory ")
                continue
            key, separator, value = line.partition("=")
            if separator and key in {"Identifier", "Format", "CodeDirectory", "Hash type", "Signature", "TeamIdentifier"}:
                safe_signature_details[key] = value
        payload = {
            "schema": 1,
            "edition": args.edition,
            # A staged bundle is verified before promotion. Record the stable
            # destination path so the report remains useful after the atomic
            # rename out of the private staging directory.
            "bundle_path": args.reported_bundle_path.as_posix() if args.reported_bundle_path else app.name,
            "bundle_id": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"],
            "source_revision": receipt["source_revision"],
            "source_dirty": receipt["source_dirty"],
            "source_manifest_sha256": receipt["source_manifest_sha256"],
            "binary_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "signature_verification": "passed",
            "signature_details": safe_signature_details,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(args.output.name + ".tmp")
        temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        temporary.replace(args.output)
        print(json.dumps(payload, sort_keys=True))
    except (IntegrityError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release info failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
