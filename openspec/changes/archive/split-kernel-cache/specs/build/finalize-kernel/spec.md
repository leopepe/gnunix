# split-kernel-cache spec

Path: `specs/build/finalize-kernel/`

Requirements:
- Cache key includes `.kernel.version`, `kernel.config`, `kernel.modules.config`.
- Skip build when artifacts present for pinned KV.
- Produced artifacts: `vmlinuz`, `config`, `System.map`, `lib/modules/`.
