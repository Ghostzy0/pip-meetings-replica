# Set up Meetings Replica

This repository contains only the Neutral Core Replica (`baseline`). Follow the README for platform requirements and use only the editions listed in `distribution.json`.

```sh
scripts/test-native.sh baseline
scripts/build-native.sh baseline
python3 scripts/setup-speech.py
python3 scripts/setup-speech.py --verify-only
open 'dist/baseline/Meetings Replica.app'
```

Initial builds and speech setup download pinned public dependencies and the explicitly documented local model files. Consult [public verification](../PUBLIC-VERIFICATION.md) for tested network and package evidence. Processing stays local after setup only for paths covered by those checks. Native recording requires the user's actual macOS permissions and participant consent; never bypass consent or upload meeting content.
