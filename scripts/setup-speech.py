#!/usr/bin/env python3
"""Download/verify pinned local speech assets. No content upload or remote scripts."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import os
import sys
import urllib.request
import uuid


def checked_path(root, relative):
    parts = PurePosixPath(relative).parts
    if not parts or any(p in ('..', '.', '') for p in parts) or relative.startswith('/'):
        raise ValueError('Unsafe asset destination')
    target = root.joinpath(*parts)
    if root not in target.resolve().parents:
        raise ValueError('An asset symlink points outside the chosen folder')
    return target


def verify_receipt(root, expected):
    receipt = checked_path(root, 'manifest.json')
    if not receipt.is_file() or receipt.stat().st_size >= 1024 * 1024:
        raise ValueError('Missing or invalid speech receipt; run setup without --verify-only to repair it')
    entries = json.loads(receipt.read_text())
    fields = ('repo', 'revision', 'local', 'size', 'sha256')
    def identities(items):
        if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
            raise ValueError('Invalid speech receipt')
        result = {item.get('local'): tuple(item.get(key) for key in fields) for item in items}
        if len(result) != len(items):
            raise ValueError('Duplicate speech receipt entries')
        return result
    if identities(entries) != identities(expected):
        raise ValueError('Speech receipt differs from pinned files; run setup again')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Library/Application Support/Pip Meetings/models/whisperkit-tiny-en')
    parser.add_argument('--verify-only', action='store_true', help='Read local files only; no network')
    options = parser.parse_args()
    manifest = json.loads((Path(__file__).resolve().parent.parent / 'docs/speech-assets.json').read_text())
    root = options.destination.expanduser().resolve()
    if not options.verify_only:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
    failed = []
    for item in manifest['files']:
        target = checked_path(root, item['local'])
        valid = target.is_file() and target.stat().st_size == item['size'] and hashlib.sha256(target.read_bytes()).hexdigest() == item['sha256']
        if valid:
            continue
        if options.verify_only:
            failed.append(item['local'])
            continue
        url = 'https://huggingface.co/{repo}/resolve/{revision}/{path}'.format(**item)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        partial = target.with_name(target.name + '.partial-' + uuid.uuid4().hex)
        try:
            digest = hashlib.sha256()
            size = 0
            with urllib.request.urlopen(url, timeout=90) as response, partial.open('xb') as output:
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    size += len(block)
                    if size > item['size']:
                        raise ValueError('Asset exceeded pinned size')
                    digest.update(block)
                    output.write(block)
            if size != item['size'] or digest.hexdigest() != item['sha256']:
                raise ValueError('Asset size or SHA-256 does not match the pinned manifest')
            os.chmod(partial, 0o600)
            partial.replace(target)
            print('Verified', item['local'])
        finally:
            partial.unlink(missing_ok=True)
    if failed:
        print('Missing or damaged assets:', ', '.join(failed), file=sys.stderr)
        return 1
    if options.verify_only:
        verify_receipt(root, manifest['files'])
    else:
        receipt = checked_path(root, 'manifest.json')
        temporary = root / ('manifest.partial-' + uuid.uuid4().hex)
        try:
            temporary.write_text(json.dumps(manifest['files'], indent=2) + '\n')
            os.chmod(temporary, 0o600)
            temporary.replace(receipt)
        finally:
            temporary.unlink(missing_ok=True)
    print('Verified all {} speech files. Choose this folder in Meetings Replica: {}'.format(len(manifest['files']), root))
    print('Code/model notices: docs/LOCAL-SPEECH.md. No meeting audio was read or uploaded.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Speech setup failed: {}'.format(error), file=sys.stderr)
        sys.exit(1)
