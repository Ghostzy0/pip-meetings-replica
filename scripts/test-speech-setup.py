#!/usr/bin/env python3
"""Read-only receipt acceptance and path-boundary regression tests."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('speech_setup', Path(__file__).with_name('setup-speech.py'))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ReceiptTests(unittest.TestCase):
    def test_missing_forged_duplicate_and_exact_receipt(self):
        expected = [{'repo': 'test/model', 'revision': 'pinned', 'local': 'model/file', 'size': 3, 'sha256': 'abc'}]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            with self.assertRaises(ValueError):
                setup.verify_receipt(root, expected)
            receipt = root / 'manifest.json'
            receipt.write_text(json.dumps(expected))
            original = receipt.read_bytes()
            setup.verify_receipt(root, expected)
            self.assertEqual(receipt.read_bytes(), original)
            for entries in (expected * 2, [{**expected[0], 'revision': 'changed'}], []):
                receipt.write_text(json.dumps(entries))
                with self.assertRaises(ValueError):
                    setup.verify_receipt(root, expected)

    def test_receipt_symlink_cannot_escape(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder).resolve()
            root = base / 'speech'
            root.mkdir()
            outside = base / 'outside.json'
            outside.write_text('[]')
            (root / 'manifest.json').symlink_to(outside)
            with self.assertRaises(ValueError):
                setup.verify_receipt(root, [])


if __name__ == '__main__':
    unittest.main()
