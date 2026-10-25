#!/usr/bin/env python3
"""Safely promote a verified Meetings bundle and preserve the prior package."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import stat
import sys
from datetime import datetime, timezone


class PromotionError(RuntimeError):
    pass


def _lexists(path: pathlib.Path) -> bool:
    return path.exists() or path.is_symlink()


def _reject_symlink(path: pathlib.Path, label: str) -> None:
    if path.is_symlink():
        raise PromotionError(f"Refusing symlinked {label}: {path}")


def _check_path_chain(path: pathlib.Path, stop: pathlib.Path, label: str) -> None:
    """Reject symlinks between a trusted app root and an output path."""
    path = pathlib.Path(os.path.abspath(path))
    stop = pathlib.Path(os.path.abspath(stop))
    try:
        relative = path.relative_to(stop)
    except ValueError as error:
        raise PromotionError(f"{label} escapes app root: {path}") from error
    current = stop
    _reject_symlink(current, label)
    for part in relative.parts:
        current = current / part
        _reject_symlink(current, label)


def _check_tree(path: pathlib.Path, label: str) -> None:
    _reject_symlink(path, label)
    if not path.is_dir():
        raise PromotionError(f"Expected a real directory for {label}: {path}")
    for item in path.rglob("*"):
        _reject_symlink(item, f"{label} member")


def _check_regular_file(path: pathlib.Path, label: str) -> None:
    _reject_symlink(path, label)
    if not path.is_file():
        raise PromotionError(f"Expected a regular file for {label}: {path}")


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _tree_inventory(root: pathlib.Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        _reject_symlink(path, "bundle member")
        if path.is_file():
            metadata = path.stat()
            entries.append({
                "path": path.relative_to(root).as_posix(),
                "size": metadata.st_size,
                "mode": stat.S_IMODE(metadata.st_mode),
                "sha256": _sha256(path),
            })
    return entries


def _verify_metadata_pair(
    executable: pathlib.Path, release_info: pathlib.Path, binary_sha: pathlib.Path, label: str,
) -> str:
    binary_hash = _sha256(executable)
    try:
        report = json.loads(release_info.read_text(encoding="utf-8"))
        checksum_lines = binary_sha.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PromotionError(f"Could not read {label} package metadata: {error}") from error
    if not isinstance(report, dict) or report.get("binary_sha256") != binary_hash:
        raise PromotionError(f"{label} release-info.json does not match its executable")
    fields = checksum_lines[0].split(maxsplit=1) if checksum_lines else []
    if not fields:
        raise PromotionError(f"{label} binary-sha256.txt has an empty or whitespace-only first line")
    if fields[0] != binary_hash:
        raise PromotionError(f"{label} binary-sha256.txt does not match its executable")
    return binary_hash


def _write_json_exclusive(path: pathlib.Path, payload: dict[str, object]) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(path, flags, 0o644)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def _replace_path(source: pathlib.Path, destination: pathlib.Path) -> None:
    os.replace(source, destination)


def _make_history_directory(history_root: pathlib.Path, edition: str, binary_hash: str) -> pathlib.Path:
    if _lexists(history_root):
        _reject_symlink(history_root, "history directory")
        if not history_root.is_dir():
            raise PromotionError(f"History path is not a directory: {history_root}")
    else:
        history_root.mkdir()

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    prefix = f"{edition}-{stamp}-{binary_hash[:12]}"
    for suffix in range(10000):
        name = prefix if suffix == 0 else f"{prefix}-{suffix:04d}"
        candidate = history_root / name
        try:
            candidate.mkdir()
            return candidate
        except FileExistsError:
            _reject_symlink(candidate, "history entry")
            if not candidate.is_dir():
                raise PromotionError(f"Existing history entry is not a directory: {candidate}")
    raise PromotionError(f"Could not allocate a unique history directory under {history_root}")


def _preserve_current(
    *, app: pathlib.Path, release_info: pathlib.Path, binary_sha: pathlib.Path,
    history_root: pathlib.Path, edition: str,
) -> pathlib.Path:
    _check_tree(app, "current bundle")
    _check_regular_file(release_info, "current release-info.json")
    _check_regular_file(binary_sha, "current binary-sha256.txt")
    executable = app / "Contents/MacOS/MeetingTranscriber"
    _check_regular_file(executable, "current executable")
    binary_hash = _verify_metadata_pair(executable, release_info, binary_sha, "Current")
    history = _make_history_directory(history_root, edition, binary_hash)
    archived_app = history / app.name
    shutil.copytree(app, archived_app, copy_function=shutil.copy2)
    archived_release = history / "release-info.json"
    archived_binary_sha = history / "binary-sha256.txt"
    release_mode = stat.S_IMODE(release_info.stat().st_mode)
    binary_sha_mode = stat.S_IMODE(binary_sha.stat().st_mode)
    shutil.copy2(release_info, archived_release)
    shutil.copy2(binary_sha, archived_binary_sha)

    original_inventory = _tree_inventory(app)
    archived_inventory = _tree_inventory(archived_app)
    if original_inventory != archived_inventory:
        raise PromotionError(f"Historical bundle copy verification failed: {history}")
    if _sha256(release_info) != _sha256(archived_release):
        raise PromotionError(f"Historical release-info copy verification failed: {history}")
    if _sha256(binary_sha) != _sha256(archived_binary_sha):
        raise PromotionError(f"Historical binary checksum copy verification failed: {history}")
    if stat.S_IMODE(archived_release.stat().st_mode) != release_mode:
        raise PromotionError(f"Historical release-info mode preservation failed: {history}")
    if stat.S_IMODE(archived_binary_sha.stat().st_mode) != binary_sha_mode:
        raise PromotionError(f"Historical binary checksum mode preservation failed: {history}")
    _write_json_exclusive(history / "preservation.json", {
        "schema": "meetings-package-preservation/v1",
        "preserved_at_utc": datetime.now(timezone.utc).isoformat(),
        "edition": edition,
        "bundle_name": app.name,
        "executable_sha256": binary_hash,
        "bundle_files": original_inventory,
        "release_info_sha256": _sha256(release_info),
        "release_info_mode": release_mode,
        "binary_sha256_file_sha256": _sha256(binary_sha),
        "binary_sha256_file_mode": binary_sha_mode,
    })
    return history


def promote(
    *, app_root: pathlib.Path, out_dir: pathlib.Path, edition: str, app_name: str,
    stage_dir: pathlib.Path, staged_bundle: pathlib.Path,
    staged_release_info: pathlib.Path, staged_binary_sha: pathlib.Path,
) -> pathlib.Path | None:
    """Promote staged artifacts; retain a verified history copy before replacement."""
    app_root = pathlib.Path(os.path.abspath(app_root))
    out_dir = pathlib.Path(os.path.abspath(out_dir))
    stage_dir = pathlib.Path(os.path.abspath(stage_dir))
    staged_bundle = pathlib.Path(os.path.abspath(staged_bundle))
    staged_release_info = pathlib.Path(os.path.abspath(staged_release_info))
    staged_binary_sha = pathlib.Path(os.path.abspath(staged_binary_sha))
    if edition not in {"baseline", "baseline-enhanced", "pip", "pip-enhanced", "upstream"}:
        raise PromotionError(f"Unsupported edition: {edition}")
    if out_dir != app_root / "dist" / edition:
        raise PromotionError(f"Output directory does not match the selected edition: {out_dir}")
    if pathlib.Path(app_name).name != app_name or not app_name.endswith(".app"):
        raise PromotionError(f"Unsafe app bundle name: {app_name}")

    _check_path_chain(out_dir, app_root, "output path")
    _check_path_chain(stage_dir, out_dir, "build staging path")
    if stage_dir.parent != out_dir or not stage_dir.name.startswith(".bundle-stage."):
        raise PromotionError(f"Build stage must be a direct .bundle-stage child of the output directory: {stage_dir}")
    _check_tree(stage_dir, "build stage")
    if staged_bundle.parent != stage_dir or staged_bundle.name != app_name:
        raise PromotionError(f"Staged bundle is outside its build stage: {staged_bundle}")
    if staged_release_info.parent != stage_dir or staged_binary_sha.parent != stage_dir:
        raise PromotionError("Staged metadata must be direct children of the build stage")
    _check_tree(staged_bundle, "staged bundle")
    _check_regular_file(staged_release_info, "staged release-info.json")
    _check_regular_file(staged_binary_sha, "staged binary-sha256.txt")
    staged_executable = staged_bundle / "Contents/MacOS/MeetingTranscriber"
    _check_regular_file(staged_executable, "staged executable")
    _verify_metadata_pair(staged_executable, staged_release_info, staged_binary_sha, "Staged")

    final_bundle = out_dir / app_name
    final_release_info = out_dir / "release-info.json"
    final_binary_sha = out_dir / "binary-sha256.txt"
    finals = (final_bundle, final_release_info, final_binary_sha)
    exists = tuple(_lexists(path) for path in finals)
    for path in finals:
        _reject_symlink(path, "existing final artifact")
    if any(exists) and not all(exists):
        raise PromotionError("Existing package is incomplete; refusing to replace a partial artifact set")
    if all(exists):
        _check_tree(final_bundle, "current bundle")
        _check_regular_file(final_release_info, "current release-info.json")
        _check_regular_file(final_binary_sha, "current binary-sha256.txt")
        _verify_metadata_pair(
            final_bundle / "Contents/MacOS/MeetingTranscriber",
            final_release_info,
            final_binary_sha,
            "Current",
        )
    staged_inventory = _tree_inventory(staged_bundle)
    staged_release_hash = _sha256(staged_release_info)
    staged_binary_sha_hash = _sha256(staged_binary_sha)

    history: pathlib.Path | None = None
    if all(exists):
        history = _preserve_current(
            app=final_bundle, release_info=final_release_info, binary_sha=final_binary_sha,
            history_root=out_dir / "historical", edition=edition,
        )

    previous_dir = stage_dir / ".previous-package"
    if _lexists(previous_dir):
        raise PromotionError(f"Rollback staging path already exists: {previous_dir}")
    previous_dir.mkdir()
    previous_paths = (
        (final_bundle, previous_dir / app_name),
        (final_release_info, previous_dir / "release-info.json"),
        (final_binary_sha, previous_dir / "binary-sha256.txt"),
    )
    promoted_paths = (
        (staged_bundle, final_bundle),
        (staged_release_info, final_release_info),
        (staged_binary_sha, final_binary_sha),
    )
    moved_previous: list[tuple[pathlib.Path, pathlib.Path]] = []
    moved_new: list[tuple[pathlib.Path, pathlib.Path]] = []
    try:
        if all(exists):
            for source, backup in previous_paths:
                _replace_path(source, backup)
                moved_previous.append((source, backup))
        for source, destination in promoted_paths:
            _replace_path(source, destination)
            moved_new.append((source, destination))
        _check_tree(final_bundle, "promoted bundle")
        _check_regular_file(final_release_info, "promoted release-info.json")
        _check_regular_file(final_binary_sha, "promoted binary-sha256.txt")
        if _tree_inventory(final_bundle) != staged_inventory:
            raise PromotionError("Promoted bundle differs from its verified staged copy")
        if _sha256(final_release_info) != staged_release_hash:
            raise PromotionError("Promoted release-info.json differs from its staged copy")
        if _sha256(final_binary_sha) != staged_binary_sha_hash:
            raise PromotionError("Promoted binary-sha256.txt differs from its staged copy")
    except Exception as error:
        rollback_errors: list[str] = []
        for staged, final in reversed(moved_new):
            try:
                _replace_path(final, staged)
            except Exception as rollback_error:  # keep both the history and rollback directory
                rollback_errors.append(f"{final} -> {staged}: {rollback_error}")
        for final, backup in reversed(moved_previous):
            try:
                if _lexists(final):
                    raise PromotionError(f"Cannot restore over existing path: {final}")
                _replace_path(backup, final)
            except Exception as rollback_error:
                rollback_errors.append(f"{backup} -> {final}: {rollback_error}")
        if rollback_errors:
            detail = "; rollback errors: " + " | ".join(rollback_errors)
        elif all(exists):
            detail = "; previous package restored and staged new artifacts retained"
        else:
            detail = "; first install left no final package and retained staged new artifacts"
        raise PromotionError(f"Package promotion failed{detail}") from error

    return history


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_root", type=pathlib.Path)
    parser.add_argument("out_dir", type=pathlib.Path)
    parser.add_argument("edition")
    parser.add_argument("app_name")
    parser.add_argument("stage_dir", type=pathlib.Path)
    parser.add_argument("staged_bundle", type=pathlib.Path)
    parser.add_argument("staged_release_info", type=pathlib.Path)
    parser.add_argument("staged_binary_sha", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        history = promote(
            app_root=args.app_root, out_dir=args.out_dir, edition=args.edition,
            app_name=args.app_name, stage_dir=args.stage_dir,
            staged_bundle=args.staged_bundle,
            staged_release_info=args.staged_release_info,
            staged_binary_sha=args.staged_binary_sha,
        )
    except (OSError, PromotionError) as error:
        print(f"Package promotion failed: {error}", file=sys.stderr)
        return 1
    if history:
        print(f"Previous package preserved at {history}")
    print("Promoted verified package and metadata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
