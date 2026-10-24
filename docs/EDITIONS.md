# Meetings Replica edition map

This repository publishes the Neutral Core Replica product only. Its default and only edition is `baseline`. It uses the separate neutral app identity and the shared local processing engine. The recreation is experimental; observed reference limits and unverified paths are in [public verification](../PUBLIC-VERIFICATION.md).

## Build

```sh
scripts/test-native.sh
scripts/build-native.sh
```

`distribution.json` is the machine-readable source of the default and allowed variants. `SOURCE-PROVENANCE.json` identifies this product and records shared-engine, source-input and public-file manifest hashes without a private repository origin or revision.
