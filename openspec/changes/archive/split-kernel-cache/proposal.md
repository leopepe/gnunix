## Why

The `finalize` stage rebuilds the kernel (~17 min) unconditionally. Splitting the kernel build artifacts (`vmlinuz`, `config`, `System.map`, `lib/modules/`) into a separate cache key lets the stage skip the build when artifacts exist for the pinned `KV`.

## What Changes

- Cache key derived from `MANIFEST` (`.kernel.version`) + `images/gnunix-base/kernel.config` + `images/gnunix-base/kernel.modules.config`.
- `04-finalize.sh` skips build when artifacts present for pinned `KV`.
- Payload: boot artifacts (`vmlinuz`, `config`, `System.map`, `lib/modules/`).

## Capabilities

- `finalize-kernel-cache`: separate kernel build caching in finalize stage.

## Impact

- `04-finalize.sh` updated; no source edits outside artifacts.
