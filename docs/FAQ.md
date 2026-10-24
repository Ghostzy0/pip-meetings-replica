# Meetings Replica questions

## What is Meetings Replica?

An experimental native macOS workspace for local meeting audio, transcripts, editable notes and source-linked decisions/actions. It extends the MIT Meeting Transcriber foundation. Granola is a workflow reference; this independent project does not claim affiliation or complete equivalence.

## What platform and setup are required?

macOS14.2+ on Apple Silicon is the intended recording platform. Source requires Swift tools6.2+ and an appropriate Xcode installation. Initial builds download pinned public dependencies. English speech setup explicitly downloads about80.4MB of separately licensed CoreML/tokenizer files. See [local speech setup](LOCAL-SPEECH.md), [AI setup](AI-SETUP.md) and actual [verification](../PUBLIC-VERIFICATION.md).

## Do I need an account or paid API?

The Neutral Core Replica requires neither. This edition uses the constrained local functional core; external note providers, automatic meeting detection, updater and debug-control routes are excluded. The separately named upstream provenance mode retains upstream capabilities and is outside the four-product comparison.

## Is processing offline?

The product is designed to process local audio with explicit local models. Setup downloads and file processing are different operations. Consult the actual network-denied fixture results in [verification](../PUBLIC-VERIFICATION.md); an installed model or successful compile alone is not proof of offline acceptance.

## Does it identify speakers or produce reliable decisions automatically?

Speech recognition and speaker processing can be wrong. Track origin is not a person's identity, and synthetic echo reduction is not speaker-accuracy evidence. Read transcripts and edit decisions/actions yourself; source links help review what was said. Do not infer due dates, attendance or ownership from uncertain text.

## What permissions and privacy limits apply?

The user controls native microphone/system-audio permissions. Only record with participant consent. Audio, meeting records and exports are local files; the app does not encrypt its store. OS disk protection and file access remain relevant. Never upload private meetings to public issues. Actual granted paths and tested operations are listed separately in verification.

## Can I move notes from Granola or another service?

There is no account sync, credential import or automatic proprietary-format migration. See the [migration guide](MIGRATION.md). Preserve originals and review any imported audio and copied text before relying on the new store.

## Are builds signed and stable?

Packages are experimental and locally ad-hoc signed, without Developer ID signing/notarisation. Native recording, long-session recovery, performance and platform limits require measured acceptance. Read the exact release notes and verification for the artifact you use; never disable security globally.
