# Meetings Replica

An independent local macOS recreation effort for selected meeting-workflow patterns described in public Granola materials. It uses the local Meetings engine and a separate Neutral Core identity. The exact live product layout and complete functional parity remain unverified; see [public verification](PUBLIC-VERIFICATION.md).

**Experimental Neutral Core Replica.** This export contains one edition: `baseline`. No Pip custom editions or upstream provenance build are included.

**Known native limits (25 Oct 2026):** The source now validates a newly created library root before canonicalizing its path; focused internal library/persistence and root-link tests passed, but were not rerun on this public candidate. A private diagnostic Replica build saved one synthetic first note but stayed on Home; the first-create process ID was not sampled. In a separate run, an existing synthetic note opened after its live process identity was verified against the intended frozen app. Recording, complete note UX and reference parity remain unverified.

[![Verify exported Meetings product](https://github.com/Ghostzy0/pip-meetings-replica/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/Ghostzy0/pip-meetings-replica/actions/workflows/verify.yml) · [Verification](PUBLIC-VERIFICATION.md) · [Report an issue](https://github.com/Ghostzy0/pip-meetings-replica/issues/1) · [Pip Meetings custom edition](https://github.com/Ghostzy0/pip-meetings)

## What it does

- Explicit native recording and local audio processing through the Meeting Transcriber foundation.
- A local library for transcripts, editable notes, decisions/actions and source references.
- Local speech files and text exports. No account or hosted runtime is required for Meetings Replica.
- A separately buildable baseline for comparison, with original upstream notices.

The Neutral Core Replica removes external note-provider, automatic watcher, updater and debug-control routes at the code boundary. The upstream provenance build is not part of this public product. See native/THIRD-PARTY-NOTICES.md and docs/LOCAL-SPEECH.md for dependencies and downloaded weights.

## Build the replica

macOS 14.2+ on Apple Silicon is the intended recording platform. The verified build host uses Xcode 27.1/Swift 6.4; Swift tools 6.2+ (Xcode 26+) is required. Intel/older OS native acceptance is unverified. The default edition is `baseline` (Meetings Replica). This repository builds only the Neutral Core Replica (`baseline`).

```sh
scripts/test-native.sh
scripts/build-native.sh
open 'dist/baseline/Meetings Replica.app'
```

Build another enabled variant explicitly:

```sh
# This product contains no additional editions.
```

Build scripts download pinned Swift dependencies/binary artifacts and a small hash-verified Apache 2.0 LocalVQE echo file. No paid service is needed. They create ad-hoc signed applications in `dist/`; these are not Developer ID signed or notarised. Never disable macOS security globally. Use a locally built app or inspect the published prerelease's actual signing/known-issue notes. See [edition map](docs/EDITIONS.md).

For speech, run `python3 scripts/setup-speech.py`, then choose its output folder in Meetings Replica. This explicitly downloads about 80.4 MB of hash-verified tiny.en files. Keep both the CoreML and tokenizer directories. Speech recognition is fallible; read the transcript before using it. [Speech setup and licences](docs/LOCAL-SPEECH.md) · [Short AI setup prompt](docs/AI-SETUP.md).

## Privacy and permissions

Only record with the participants' consent. Microphone and system-audio access are native OS approvals made by the user. Do not use real meetings for development. A headset helps reduce acoustic echo; source labels and automatic diarisation must not be assumed to identify people accurately.

Meetings Replica's meetings, recordings and notes live in its own Application Support directory. Speech files stay in their chosen local folder. Local storage is not encrypted by this app; OS storage protection remains relevant. Exported files are separate copies and must be reviewed before sharing. The application must not upload meeting content. Model/setup downloads are distinct from processing content offline; see the actual network-denied test evidence in [verification](PUBLIC-VERIFICATION.md).

No upstream provenance build is included in this export. The distributed editions do not import another app's credentials. Model downloads and native grants do not establish complete offline or microphone acceptance.

## Help, changes and contributing

Maintainer: [Ghostzy0](https://github.com/Ghostzy0). [Change notes](CHANGELOG.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md), [upstream provenance](UPSTREAM.md), [Granola workflow documentation](https://docs.granola.ai/help-center/taking-notes/transcription). Use repository issues for reproducible bugs without private audio, screenshots or account data. Do not post sensitive information in public reports.

Pictures and release links are added only when genuine synthetic renders and reviewed artifacts are available. There is no hosted runtime dependency.

[Frequently asked questions](docs/FAQ.md) · [Move existing material](docs/MIGRATION.md)
