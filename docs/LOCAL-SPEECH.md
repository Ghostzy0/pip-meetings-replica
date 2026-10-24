# Local speech files

The default speech setup uses pinned WhisperKit tiny.en CoreML assets and an English tokenizer. It needs no account. This small English model is useful for first setup and synthetic verification; recognition may be inaccurate. Read the text before relying on it. Other local engines/models need their own model-file and licence verification.

Run from the repository root after installing Xcode26+ (Swift6.2+) and Python3:

```sh
python3 scripts/setup-speech.py
python3 scripts/setup-speech.py --verify-only
```

Initial setup explicitly downloads about80.4MB over HTTPS from Hugging Face; it uploads no audio or screenshots. The manifest pins28 exact files, repository revisions, byte sizes and SHA256 digests. The setup script defaults to `~/Library/Application Support/Pip Meetings/models/whisperkit-tiny-en`; in Meetings Replica choose **Speech folder** and select that directory (or pass `--destination` to setup another location). This folder contains `openai_whisper-tiny.en/` and `tokenizer/`. Preserve both; weights alone do not establish offline operation. The app refuses missing local resources rather than falling back to a cloud transcriber. See PUBLIC-VERIFICATION.md for actual network-denied fixture evidence when recorded.

Sources and licences:

- CoreML conversion: [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482), revision0f63a7800b00dd0226abd051b906c246e1907482, MIT model-card declaration; derived from Whisper. All CoreML tiny.en files in this setup are pinned by hash in speech-assets.json.
- Tokenizer/configuration: [openai/whisper-tiny.en](https://huggingface.co/openai/whisper-tiny.en/tree/87c7102498dcde7456f24cfd30239ca606ed9063), revision87c7102498dcde7456f24cfd30239ca606ed9063, Apache-2.0 model-card declaration. The downloaded tokenizer README preserves attribution/licence information.
- Engine: [WhisperKit1.1.0](https://github.com/argmaxinc/WhisperKit/tree/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d), MIT with propagated upstream notices. See native/licenses and THIRD-PARTY-NOTICES.

Model files are downloaded locally by the user; they are not source Git files or release attachments. Local disk data is not encrypted by this app; use appropriate operating-system protection. Removing this app does not silently remove downloaded weights or meeting data.
