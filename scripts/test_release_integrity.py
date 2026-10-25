#!/usr/bin/env python3
import json
import hashlib
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from release_integrity import (  # noqa: E402
    EDITION,
    IntegrityError,
    RESOURCE_MANIFEST,
    RESOURCE_RECEIPT,
    check_distribution_edition,
    distribution_config,
    manifest_digest,
    source_manifest,
    source_revision,
    verify_package,
    write_receipt,
)


FIXED_INPUTS = (
    "scripts/build-native.sh",
    "scripts/test-native.sh",
    "scripts/release_integrity.py",
    "scripts/release-info.py",
    "scripts/promote_package.py",
    "scripts/test_release_integrity.py",
    "scripts/test_package_promotion.py",
    "native/VERSION",
    "native/LICENSE",
    "native/THIRD-PARTY-NOTICES.md",
    "native/app/MeetingTranscriber/Package.swift",
    "native/app/MeetingTranscriber/Package.resolved",
    "native/tools/audiotap/Package.swift",
    "native/scripts/fetch-localvqe-model.sh",
    "native/scripts/lib/bundle-licenses.sh",
    "native/scripts/lib/localvqe-resources.sh",
)
INPUT_DIRS = (
    "native/app/MeetingTranscriber/Sources",
    "native/app/MeetingTranscriber/Tests",
    "native/app/MeetingTranscriber/Entitlements",
    "native/tools/audiotap/Sources",
    "native/tools/audiotap/Tests",
    "native/licenses",
)


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        for item in FIXED_INPUTS:
            path = self.root / item
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture " + item, encoding="utf-8")
        for item in INPUT_DIRS:
            path = self.root / item
            path.mkdir(parents=True, exist_ok=True)
            (path / "fixture.swift").write_text("fixture " + item, encoding="utf-8")
        self.app = self.root / "dist/Pip Meetings.app"
        self.executable = self.app / "Contents/MacOS/MeetingTranscriber"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"fixture executable")
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)
        self.license = self.resources / "licenses/LocalVQE.txt"
        self.license.parent.mkdir()
        self.license.write_text("license text")
        name, bundle_id, version, _flags = EDITION["pip"]
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleName": name,
                "CFBundleDisplayName": name,
                "CFBundleIdentifier": bundle_id,
                "CFBundleShortVersionString": version,
            }, stream)
        self.manifest_path = self.root / "source-manifest.json"
        self.manifest = source_manifest(self.root)
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")
        self.digest = manifest_digest(self.manifest)
        write_receipt(self.root, self.app, "pip", self.manifest_path, self.digest)

    def tearDown(self):
        self.temp.cleanup()

    def test_manifest_is_stable_sorted_and_covers_source_tests_and_build_inputs(self):
        manifest = source_manifest(self.root)
        paths = [item["path"] for item in manifest["files"]]
        self.assertEqual(paths, sorted(paths))
        for expected in (
            "native/app/MeetingTranscriber/Package.swift",
            "native/app/MeetingTranscriber/Tests/fixture.swift",
            "native/tools/audiotap/Tests/fixture.swift",
            "native/licenses/fixture.swift",
            "scripts/build-native.sh",
        ):
            self.assertIn(expected, paths)

    def test_matching_receipt_and_resources_verify(self):
        receipt = verify_package(self.root, self.app, "pip")
        self.assertEqual(receipt["source_manifest_sha256"], self.digest)
        self.assertEqual(receipt["compiler_flags"], ["-DPIP_EDITION"])
        self.assertEqual(receipt["resources"][0]["path"], "licenses/LocalVQE.txt")

    def test_replica_is_confined_to_neutral_baseline_flags(self):
        self.assertEqual(
            EDITION["baseline"][3],
            ["-DPIP_EDITION", "-DPIP_NEUTRAL", "-DMEETINGS_REPLICA"],
        )
        for edition in ("baseline-enhanced", "pip", "pip-enhanced"):
            self.assertNotIn("-DMEETINGS_REPLICA", EDITION[edition][3])
        self.assertEqual(EDITION["baseline"][:2], ("Meetings Replica", "uk.pipreps.meetings.replica"))
        self.assertEqual(EDITION["baseline-enhanced"][:2], ("Meetings Baseline Enhanced", "uk.pipreps.meetings.neutral.enhanced"))
        self.assertEqual(EDITION["baseline-enhanced"][3], ["-DPIP_EDITION", "-DPIP_NEUTRAL", "-DMEETINGS_ENHANCEMENTS"])

    def test_optional_distribution_defaults_and_fingerprints_clean_exports(self):
        self.assertEqual(distribution_config(self.root)["default_edition"], "pip")
        self.assertEqual(
            distribution_config(self.root)["editions"],
            ["baseline", "baseline-enhanced", "pip", "pip-enhanced"],
        )
        path = self.root / "distribution.json"
        path.write_text(json.dumps({"default_edition": "baseline", "editions": ["baseline"]}), encoding="utf-8")
        before = manifest_digest(source_manifest(self.root))
        self.assertEqual(distribution_config(self.root)["default_edition"], "baseline")
        check_distribution_edition(self.root, "baseline")
        with self.assertRaisesRegex(IntegrityError, "not included"):
            check_distribution_edition(self.root, "pip")

        path.write_text(json.dumps({
            "default_edition": "pip",
            "editions": ["baseline-enhanced", "pip", "pip-enhanced"],
        }), encoding="utf-8")
        after = manifest_digest(source_manifest(self.root))
        self.assertNotEqual(before, after)
        self.assertEqual(distribution_config(self.root)["default_edition"], "pip")
        script = pathlib.Path(__file__).with_name("release_integrity.py")
        supported = subprocess.run(
            [sys.executable, str(script), "distribution-list", str(self.root)],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        self.assertEqual(supported, "baseline-enhanced pip pip-enhanced")
        self.assertIn("distribution.json", [item["path"] for item in source_manifest(self.root)["files"]])

    def test_optional_distribution_rejects_wrong_export_shape_and_symlinks(self):
        path = self.root / "distribution.json"
        path.write_text(json.dumps({"default_edition": "pip", "editions": ["pip"]}), encoding="utf-8")
        with self.assertRaisesRegex(IntegrityError, "must define the neutral baseline"):
            distribution_config(self.root)
        path.unlink()
        target = self.root / "target.json"
        target.write_text('{"default_edition":"baseline","editions":["baseline"]}', encoding="utf-8")
        path.symlink_to(target)
        with self.assertRaisesRegex(IntegrityError, "is a symlink"):
            source_manifest(self.root)

    def test_same_bundle_identity_with_changed_source_is_stale(self):
        (self.root / "native/app/MeetingTranscriber/Sources/fixture.swift").write_text("changed source")
        with self.assertRaisesRegex(IntegrityError, "source inputs are stale"):
            verify_package(self.root, self.app, "pip")

    def test_source_change_between_manifest_and_receipt_stops_packaging(self):
        (self.root / "native/app/MeetingTranscriber/Sources/fixture.swift").write_text("changed during build")
        with self.assertRaisesRegex(IntegrityError, "Source changed during build"):
            write_receipt(self.root, self.app, "pip", self.manifest_path, self.digest)

    def test_resource_change_after_receipt_is_rejected(self):
        self.license.write_text("different license bytes")
        with self.assertRaisesRegex(IntegrityError, "receipt does not match"):
            verify_package(self.root, self.app, "pip")

    def test_wrong_edition_or_compile_defines_are_rejected(self):
        receipt_path = self.resources / RESOURCE_RECEIPT
        receipt = json.loads(receipt_path.read_text())
        receipt["compiler_flags"] = ["-DPIP_NEUTRAL"]
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(IntegrityError, "receipt does not match"):
            verify_package(self.root, self.app, "pip")

    def test_wrong_git_revision_or_dirty_state_is_rejected(self):
        receipt_path = self.resources / RESOURCE_RECEIPT
        receipt = json.loads(receipt_path.read_text())
        receipt["source_revision"] = "unrelated-revision"
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(IntegrityError, "receipt does not match"):
            verify_package(self.root, self.app, "pip")

    def test_symlinked_selected_source_is_rejected(self):
        source = self.root / "native/app/MeetingTranscriber/Sources/fixture.swift"
        replacement = source.with_suffix(".real")
        source.rename(replacement)
        source.symlink_to(replacement.name)
        with self.assertRaisesRegex(IntegrityError, "symlink"):
            source_manifest(self.root)

    def test_unversioned_checkout_has_manifest_only_identity(self):
        self.assertEqual(source_revision(self.root), ("unversioned", None))

    def test_manifest_receipt_and_verify_cli_round_trip(self):
        script = pathlib.Path(__file__).with_name("release_integrity.py")
        cli_manifest = self.root / "cli-manifest.json"
        generated = subprocess.run(
            [sys.executable, str(script), "manifest", str(self.root), str(cli_manifest)],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        subprocess.run(
            [sys.executable, str(script), "receipt", str(self.root), str(self.app), "pip", str(cli_manifest), generated],
            check=True, capture_output=True, text=True,
        )
        checked = subprocess.run(
            [sys.executable, str(script), "verify", str(self.root), str(self.app), "pip"],
            check=True, capture_output=True, text=True,
        )
        self.assertEqual(json.loads(checked.stdout)["source_manifest_sha256"], generated)

    def test_postsign_release_info_reports_promoted_bundle_path(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_codesign = fake_bin / "codesign"
        fake_codesign.write_text(
            "#!/bin/sh\nif [ \"$1\" = \"-dv\" ]; then echo 'Identifier=uk.pipreps.meetings' >&2; echo 'Signature=adhoc' >&2; echo 'Executable=/Users/private/Pip Meetings.app/Contents/MacOS/MeetingTranscriber' >&2; echo 'CodeDirectory v=20400 size=100 flags=0x0(none)' >&2; else echo 'valid on disk' >&2; fi\n",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        script = pathlib.Path(__file__).with_name("release-info.py")
        output = self.root / "release-info.json"
        reported = pathlib.Path("dist/promoted/Pip Meetings.app")
        import os
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ.get("PATH", ""))
        subprocess.run(
            [sys.executable, str(script), str(self.root), str(self.app), "pip", str(output), "--reported-bundle-path", str(reported)],
            env=env, check=True, capture_output=True, text=True,
        )
        release = json.loads(output.read_text())
        self.assertEqual(release["bundle_path"], reported.as_posix())
        self.assertEqual(release["signature_verification"], "passed")
        self.assertEqual(release["binary_sha256"], hashlib.sha256(self.executable.read_bytes()).hexdigest())
        self.assertEqual(release["signature_details"], {
            "Identifier": "uk.pipreps.meetings",
            "CodeDirectory": "v=20400 size=100 flags=0x0(none)",
            "Signature": "adhoc",
        })
        self.assertNotIn(str(self.root), output.read_text())
        self.assertNotIn("/Users/private", output.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
