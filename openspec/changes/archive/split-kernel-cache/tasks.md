- [ ] 1.1 Define cache key from `.kernel.version` + `images/gnunix-base/kernel.config` + `images/gnunix-base/kernel.modules.config`.
  depends-on: `finalize-stage`
  touches: `04-finalize.sh`
- [ ] 1.2 Make `04-finalize.sh` skip kernel build when artifacts present for pinned `KV`.
  depends-on: `1.1`
  touches: `images/gnunix-base/stages/04-finalize.sh`
- [ ] 1.3 Define payload artifacts: `vmlinuz`, `config`, `System.map`, `lib/modules/`.
  depends-on: `1.2`
  touches: `images/gnunix-base/stages/04-finalize.sh`
