#!/usr/bin/env python3
from __future__ import annotations
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import promote_package as promotion  # noqa: E402


class PackagePromotionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.out = self.root / "dist/pip"
        self.out.mkdir(parents=True)
        self.app_name = "Pip Meetings.app"
        self.final_app = self.out / self.app_name
        self.final_release = self.out / "release-info.json"
        self.final_binary_sha = self.out / "binary-sha256.txt"
        (self.final_app / "Contents/MacOS").mkdir(parents=True)
        old_executable = b"old executable"
        (self.final_app / "Contents/MacOS/MeetingTranscriber").write_bytes(old_executable)
        (self.final_app / "Contents/Info.plist").write_bytes(b"old plist")
        old_hash = hashlib.sha256(old_executable).hexdigest()
        self.old_release_bytes = (json.dumps({"generation": "old", "binary_sha256": old_hash}) + "\n").encode()
        self.old_binary_sha_bytes = f"{old_hash}  MeetingTranscriber\n".encode()
        self.final_release.write_bytes(self.old_release_bytes)
        self.final_binary_sha.write_bytes(self.old_binary_sha_bytes)
        self.final_release.chmod(0o640)
        self.final_binary_sha.chmod(0o600)
        self.unrelated = self.out / "keep-me.txt"
        self.unrelated.write_text("unrelated user-owned output\n", encoding="utf-8")
        self.stage = self.new_stage(b"new executable", "new")

    def tearDown(self):
        self.temp.cleanup()

    def new_stage(self, executable: bytes, generation: str) -> pathlib.Path:
        stage = self.out / f".bundle-stage.{generation}"
        stage.mkdir()
        app = stage / self.app_name
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/MeetingTranscriber").write_bytes(executable)
        (app / "Contents/Info.plist").write_bytes(f"{generation} plist".encode())
        executable_hash = hashlib.sha256(executable).hexdigest()
        (stage / "release-info.json").write_text(
            json.dumps({"generation": generation, "binary_sha256": executable_hash}) + "\n", encoding="utf-8"
        )
        (stage / "binary-sha256.txt").write_text(
            f"{executable_hash}  MeetingTranscriber\n", encoding="utf-8"
        )
        return stage

    def promote_stage(self, stage: pathlib.Path) -> pathlib.Path | None:
        return promotion.promote(
            app_root=self.root,
            out_dir=self.out,
            edition="pip",
            app_name=self.app_name,
            stage_dir=stage,
            staged_bundle=stage / self.app_name,
            staged_release_info=stage / "release-info.json",
            staged_binary_sha=stage / "binary-sha256.txt",
        )

    def test_success_archives_previous_triplet_and_preserves_existing_history(self):
        prior_history = self.out / "historical/hand-created-history"
        prior_history.mkdir(parents=True)
        marker = prior_history / "owner-file.txt"
        marker.write_text("must remain unchanged\n", encoding="utf-8")

        history = self.promote_stage(self.stage)

        self.assertIsNotNone(history)
        self.assertTrue(history.is_dir())
        self.assertNotEqual(history, prior_history)
        self.assertEqual((history / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old executable")
        self.assertEqual((history / "release-info.json").read_bytes(), self.old_release_bytes)
        self.assertEqual((history / "binary-sha256.txt").read_bytes(), self.old_binary_sha_bytes)
        self.assertEqual(stat.S_IMODE((history / "release-info.json").stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE((history / "binary-sha256.txt").stat().st_mode), 0o600)
        preservation = json.loads((history / "preservation.json").read_text(encoding="utf-8"))
        self.assertEqual(preservation["executable_sha256"], hashlib.sha256(b"old executable").hexdigest())
        self.assertEqual(preservation["release_info_mode"], 0o640)
        self.assertEqual(preservation["binary_sha256_file_mode"], 0o600)
        self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")
        self.assertEqual(json.loads(self.final_release.read_text())["generation"], "new")
        self.assertEqual(self.final_binary_sha.read_text().split()[0], hashlib.sha256(b"new executable").hexdigest())
        self.assertEqual(marker.read_text(encoding="utf-8"), "must remain unchanged\n")
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "unrelated user-owned output\n")

        first_history_bytes = (history / "preservation.json").read_bytes()
        second_stage = self.new_stage(b"newer executable", "newer")
        second_history = self.promote_stage(second_stage)
        self.assertNotEqual(history, second_history)
        self.assertEqual((history / "preservation.json").read_bytes(), first_history_bytes)
        self.assertEqual(marker.read_text(encoding="utf-8"), "must remain unchanged\n")

    def test_partial_promotion_failure_restores_old_triplet_and_keeps_new_stage(self):
        real_replace = promotion._replace_path
        failed = False

        def fail_release_promotion_once(source, destination):
            nonlocal failed
            if source == self.stage / "release-info.json" and destination == self.final_release and not failed:
                failed = True
                raise OSError("injected metadata promotion failure")
            return real_replace(source, destination)

        with mock.patch.object(promotion, "_replace_path", side_effect=fail_release_promotion_once):
            with self.assertRaisesRegex(promotion.PromotionError, "previous package restored"):
                self.promote_stage(self.stage)

        self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old executable")
        self.assertEqual(self.final_release.read_bytes(), self.old_release_bytes)
        self.assertEqual(self.final_binary_sha.read_bytes(), self.old_binary_sha_bytes)
        self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")
        self.assertEqual(json.loads((self.stage / "release-info.json").read_text(encoding="utf-8"))["generation"], "new")
        histories = list((self.out / "historical").iterdir())
        self.assertEqual(len(histories), 1)
        self.assertTrue((histories[0] / "preservation.json").is_file())
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "unrelated user-owned output\n")

    def test_first_install_promotes_without_history(self):
        for path in (self.final_app, self.final_release, self.final_binary_sha):
            if path.is_dir():
                import shutil
                shutil.rmtree(path)
            else:
                path.unlink()
        history = self.promote_stage(self.stage)
        self.assertIsNone(history)
        self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")
        self.assertFalse((self.out / "historical").exists())
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "unrelated user-owned output\n")

    def test_first_install_partial_promotion_failure_leaves_no_final_triplet(self):
        for path in (self.final_app, self.final_release, self.final_binary_sha):
            if path.is_dir():
                import shutil
                shutil.rmtree(path)
            else:
                path.unlink()
        real_replace = promotion._replace_path

        def fail_release_promotion_once(source, destination):
            if source == self.stage / "release-info.json" and destination == self.final_release:
                raise OSError("injected first-install metadata promotion failure")
            return real_replace(source, destination)

        with mock.patch.object(promotion, "_replace_path", side_effect=fail_release_promotion_once):
            with self.assertRaisesRegex(promotion.PromotionError, "first install left no final package"):
                self.promote_stage(self.stage)

        self.assertFalse(self.final_app.exists())
        self.assertFalse(self.final_release.exists())
        self.assertFalse(self.final_binary_sha.exists())
        self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")
        self.assertEqual(json.loads((self.stage / "release-info.json").read_text(encoding="utf-8"))["generation"], "new")
        self.assertEqual((self.stage / "binary-sha256.txt").read_text(encoding="utf-8").split()[0], hashlib.sha256(b"new executable").hexdigest())
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "unrelated user-owned output\n")

    def test_metadata_copy_mode_mismatch_fails_before_replacement(self):
        real_copy2 = promotion.shutil.copy2

        def tamper_release_mode(source, destination, *args, **kwargs):
            copied = real_copy2(source, destination, *args, **kwargs)
            if pathlib.Path(source) == self.final_release:
                pathlib.Path(destination).chmod(0o644)
            return copied

        with mock.patch.object(promotion.shutil, "copy2", side_effect=tamper_release_mode):
            with self.assertRaisesRegex(promotion.PromotionError, "release-info mode preservation failed"):
                self.promote_stage(self.stage)

        self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old executable")
        self.assertEqual(self.final_release.read_bytes(), self.old_release_bytes)
        self.assertEqual(self.final_binary_sha.read_bytes(), self.old_binary_sha_bytes)
        self.assertEqual(stat.S_IMODE(self.final_release.stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE(self.final_binary_sha.stat().st_mode), 0o600)
        self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")

    def test_whitespace_checksum_fails_clearly_before_mutation(self):
        for invalid_content in ("", " \t\n"):
            with self.subTest(invalid_content=invalid_content):
                self.final_binary_sha.write_text(invalid_content, encoding="utf-8")
                with self.assertRaisesRegex(promotion.PromotionError, "empty or whitespace-only first line"):
                    self.promote_stage(self.stage)
                self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old executable")
                self.assertEqual(self.final_release.read_bytes(), self.old_release_bytes)
                self.assertFalse((self.out / "historical").exists())
                self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")

    def test_symlinked_final_path_fails_closed_without_touching_target(self):
        outside = self.root / "outside.app"
        (outside / "Contents/MacOS").mkdir(parents=True)
        sentinel = outside / "Contents/MacOS/MeetingTranscriber"
        sentinel.write_bytes(b"must stay untouched")
        import shutil
        shutil.rmtree(self.final_app)
        self.final_app.symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(promotion.PromotionError, "symlinked existing final artifact"):
            self.promote_stage(self.stage)

        self.assertEqual(sentinel.read_bytes(), b"must stay untouched")
        self.assertEqual(json.loads(self.final_release.read_text(encoding="utf-8"))["generation"], "old")
        self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")

    def test_symlinked_history_root_fails_closed_without_touching_previous_package(self):
        outside = self.root / "outside-history"
        outside.mkdir()
        marker = outside / "owner-file.txt"
        marker.write_text("must remain unchanged\n", encoding="utf-8")
        (self.out / "historical").symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(promotion.PromotionError, "symlinked history directory"):
            self.promote_stage(self.stage)

        self.assertEqual(marker.read_text(encoding="utf-8"), "must remain unchanged\n")
        self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old executable")
        self.assertEqual(self.final_release.read_bytes(), self.old_release_bytes)
        self.assertEqual(self.final_binary_sha.read_bytes(), self.old_binary_sha_bytes)
        self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")

    def test_partial_existing_package_fails_closed(self):
        self.final_binary_sha.unlink()
        with self.assertRaisesRegex(promotion.PromotionError, "package is incomplete"):
            self.promote_stage(self.stage)
        self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old executable")
        self.assertEqual(json.loads(self.final_release.read_text(encoding="utf-8"))["generation"], "old")
        self.assertFalse((self.out / "historical").exists())
        self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")

    def test_mismatched_previous_metadata_fails_closed(self):
        self.final_release.write_text(
            json.dumps({"generation": "old", "binary_sha256": "wrong-hash"}) + "\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(promotion.PromotionError, "release-info.json does not match"):
            self.promote_stage(self.stage)
        self.assertEqual((self.final_app / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old executable")
        self.assertFalse((self.out / "historical").exists())
        self.assertEqual((self.stage / self.app_name / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"new executable")


class BuildWrapperIntegrationTests(unittest.TestCase):
    """Run the real build wrapper with stubbed external tools and resource installers."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name) / "meetings-app"
        self.scripts = self.root / "scripts"
        self.native = self.root / "native"
        self.out = self.root / "dist/pip"
        self.fake_bin = pathlib.Path(self.temp.name) / "fake-bin"
        self.fake_bin.mkdir()
        self.root.mkdir()
        source_root = pathlib.Path(__file__).resolve().parents[1]

        for relative in (
            "scripts/build-native.sh",
            "scripts/test-native.sh",
            "scripts/release_integrity.py",
            "scripts/release-info.py",
            "scripts/promote_package.py",
            "scripts/test_release_integrity.py",
            "scripts/test_package_promotion.py",
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_root / relative, destination)

        for relative in (
            "native/VERSION",
            "native/LICENSE",
            "native/THIRD-PARTY-NOTICES.md",
            "native/app/MeetingTranscriber/Package.swift",
            "native/app/MeetingTranscriber/Package.resolved",
            "native/tools/audiotap/Package.swift",
            "native/scripts/fetch-localvqe-model.sh",
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text("fixture input for wrapper integration\n", encoding="utf-8")

        info = {
            "CFBundleIdentifier": "app.meetingtranscriber",
            "CFBundleName": "Meeting Transcriber",
            "CFBundleDisplayName": "Meeting Transcriber",
            "CFBundleExecutable": "MeetingTranscriber",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIconName": "AppIcon",
            "LSUIElement": True,
        }
        source_info = self.native / "app/MeetingTranscriber/Sources/Info.plist"
        source_info.parent.mkdir(parents=True, exist_ok=True)
        source_info.write_bytes(plistlib.dumps(info))
        (self.native / "app/MeetingTranscriber/Entitlements").mkdir(parents=True)
        (self.native / "app/MeetingTranscriber/Entitlements/Homebrew.entitlements").write_text("fixture entitlements\n", encoding="utf-8")
        for relative in (
            "native/app/MeetingTranscriber/Sources",
            "native/app/MeetingTranscriber/Tests",
            "native/app/MeetingTranscriber/Entitlements",
            "native/tools/audiotap/Sources",
            "native/tools/audiotap/Tests",
            "native/licenses",
        ):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
            (self.root / relative / "fixture.swift").write_text("// wrapper fixture\n", encoding="utf-8")
        (self.native / "licenses/Fixture.txt").write_text("fixture license\n", encoding="utf-8")
        (self.native / "fixture-model.gguf").write_bytes(b"stub fixture model")

        licenses_stub = self.native / "scripts/lib/bundle-licenses.sh"
        licenses_stub.parent.mkdir(parents=True, exist_ok=True)
        licenses_stub.write_text(
            'install_third_party_licenses() { mkdir -p "$1/licenses"; cp "$NATIVE_ROOT/licenses/"*.txt "$1/licenses/"; }\n',
            encoding="utf-8",
        )
        model_stub = self.native / "scripts/lib/localvqe-resources.sh"
        model_stub.write_text(
            'install_localvqe_resources() { mkdir -p "$1"; cp "$NATIVE_ROOT/fixture-model.gguf" "$1/localvqe-fixture.gguf"; }\n',
            encoding="utf-8",
        )

        self._write_executable(self.fake_bin / "swift", """#!/bin/bash
scratch=''
show_path=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --scratch-path) scratch="$2"; shift 2 ;;
        --show-bin-path) show_path=1; shift ;;
        *) shift ;;
    esac
done
bin_dir="$scratch/mock-release-bin"
if [ "$show_path" -eq 1 ]; then printf '%s\\n' "$bin_dir"; exit 0; fi
mkdir -p "$bin_dir"
printf 'mock swift executable\\n' > "$bin_dir/MeetingTranscriber"
chmod +x "$bin_dir/MeetingTranscriber"
""")
        self._write_executable(self.fake_bin / "codesign", """#!/bin/bash
last=''
for arg do last="$arg"; done
case "$1" in
    --force)
        mkdir -p "$last/Contents/_CodeSignature"
        printf 'stubbed code signature\\n' > "$last/Contents/_CodeSignature/CodeResources"
        ;;
    --verify)
        echo 'stub signature verified' >&2
        ;;
    -dv)
        echo 'Identifier=uk.pipreps.meetings' >&2
        echo 'Format=app bundle with Mach-O thin (arm64)' >&2
        echo 'CodeDirectory v=20400 size=100 flags=0x2(adhoc)' >&2
        echo 'Signature=adhoc' >&2
        echo 'TeamIdentifier=not set' >&2
        ;;
    *) echo "unexpected codesign invocation: $*" >&2; exit 2 ;;
esac
""")
        self.plist_tool = pathlib.Path(self.temp.name) / "PlistBuddy"
        self._write_executable(self.plist_tool, """#!/usr/bin/env python3
import plistlib, sys
operation = sys.argv[2].split()
path = sys.argv[3]
with open(path, 'rb') as stream: value = plistlib.load(stream)
verb, key = operation[:2]
key = key.lstrip(':')
if verb == 'Delete':
    value.pop(key, None)
elif verb == 'Add':
    value[key] = operation[3]
elif verb == 'Set':
    raw = ' '.join(operation[2:])
    value[key] = (raw.lower() == 'true') if key == 'LSUIElement' and raw.lower() in ('true', 'false') else raw
else:
    raise SystemExit('unsupported PlistBuddy command: ' + sys.argv[2])
with open(path, 'wb') as stream: plistlib.dump(value, stream)
""")

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def _write_executable(path: pathlib.Path, content: str):
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _seed_old_package(self):
        bundle = self.out / "Pip Meetings.app"
        executable = bundle / "Contents/MacOS/MeetingTranscriber"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(b"old wrapper package")
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "uk.pipreps.meetings"}))
        release_info = {"binary_sha256": digest, "generation": "old"}
        (self.out / "release-info.json").write_text(json.dumps(release_info) + "\n", encoding="utf-8")
        (self.out / "binary-sha256.txt").write_text(f"{digest}  MeetingTranscriber\n", encoding="utf-8")
        return bundle, (self.out / "release-info.json").read_bytes(), (self.out / "binary-sha256.txt").read_bytes()

    def _run_build(self):
        env = dict(os.environ)
        env["PATH"] = str(self.fake_bin) + os.pathsep + env.get("PATH", "")
        env["MEETINGS_PLIST_BUDDY"] = str(self.plist_tool)
        return subprocess.run(
            ["bash", str(self.scripts / "build-native.sh"), "pip"],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_build_wrapper_promotes_named_app_with_stubbed_toolchain(self):
        old_bundle, old_release, old_binary_sha = self._seed_old_package()
        result = self._run_build()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        final_bundle = self.out / "Pip Meetings.app"
        self.assertEqual((final_bundle / "Contents/MacOS/MeetingTranscriber").read_text(), "mock swift executable\n")
        final_release = json.loads((self.out / "release-info.json").read_text(encoding="utf-8"))
        self.assertEqual(final_release["bundle_path"], "dist/pip/Pip Meetings.app")
        self.assertEqual(final_release["signature_verification"], "passed")
        history = list((self.out / "historical").iterdir())
        self.assertEqual(len(history), 1)
        self.assertEqual((history[0] / "Pip Meetings.app/Contents/MacOS/MeetingTranscriber").read_bytes(), b"old wrapper package")
        self.assertEqual((history[0] / "release-info.json").read_bytes(), old_release)
        self.assertEqual((history[0] / "binary-sha256.txt").read_bytes(), old_binary_sha)
        self.assertEqual((old_bundle / "Contents/MacOS/MeetingTranscriber").read_text(), "mock swift executable\n")
        self.assertEqual(list(self.out.glob(".bundle-stage.*")), [])

    def test_build_wrapper_retains_staged_artifacts_when_promotion_fails(self):
        old_bundle, old_release, old_binary_sha = self._seed_old_package()
        outside = pathlib.Path(self.temp.name) / "outside-history"
        outside.mkdir()
        (self.out / "historical").symlink_to(outside, target_is_directory=True)

        result = self._run_build()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Refusing symlinked history directory", result.stderr)
        self.assertIn("Retained failed package stage for recovery", result.stderr)
        self.assertEqual((old_bundle / "Contents/MacOS/MeetingTranscriber").read_bytes(), b"old wrapper package")
        self.assertEqual((self.out / "release-info.json").read_bytes(), old_release)
        self.assertEqual((self.out / "binary-sha256.txt").read_bytes(), old_binary_sha)
        stages = list(self.out.glob(".bundle-stage.*"))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0] / "Pip Meetings.app/Contents/MacOS/MeetingTranscriber").is_file())
        self.assertTrue((stages[0] / "release-info.json").is_file())
        self.assertTrue((stages[0] / "binary-sha256.txt").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
