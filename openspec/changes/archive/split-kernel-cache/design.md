# split-kernel-cache design

## Context

`images/gnunix-base/stages/04-finalize.sh` builds kernel in finalize stage.

## Goals

Split kernel build into separate cache key based on pinned `KV` and config inputs.

## Non-goals

Not changing the kernel version or build process; only caching.
