#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Locks every test project again, with the network, and fails when a
# lockfile differs from the committed one by a single byte. The lock run
# needs the network, so this runs outside the Nix sandbox: in CI, and by
# hand from the repository root as `tests/relock.sh`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
lock() { nix run "$root" -- lock "$@"; }

for fixture in tests/fixtures/*/; do
  lock --root "$fixture"
  rm -rf "$fixture/node_modules"
done
git diff --exit-code -- tests/fixtures

# deployctl at the commit tests/dependencies pins, with the deno.lock of
# tests/real/deployctl in place of its own out-of-date one.
rev="$(nix flake metadata --json ./tests/dependencies | jq -r '.locks.nodes.deployctl.locked.rev')"
source="$(nix flake prefetch --json "github:denoland/deployctl/$rev" | jq -r .storePath)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -r "$source/." "$work/deployctl"
chmod -R u+w "$work/deployctl"
cp tests/real/deployctl/deno.lock "$work/deployctl/deno.lock"
# The lockfile lives outside deployctl's source, as a packaging flake keeps
# it.
lock --root "$work/deployctl" --lockfile "$work/deno-purifier.lock.json"
cmp "$work/deployctl/deno.lock" tests/real/deployctl/deno.lock
cmp "$work/deno-purifier.lock.json" tests/real/deployctl/deno-purifier.lock.json
echo "relock: every lockfile is reproduced byte for byte"
