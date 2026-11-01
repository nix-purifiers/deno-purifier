#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update check of the purifier contract. It runs
# `deno-purifier update` on a copy of tests/fixtures/update, whose deno.lock
# pins @std/path 1.0.0 under the requirement ^1.0.0, and fails unless
# deno.lock then pins a newer version and Nix accepts both lockfiles: the
# prefetch evaluates them through the purifier library's checkLock, and the
# deno wrapper checks deno.lock against deno-purifier.lock.json. The update
# needs the network, so this runs outside the Nix sandbox: in CI, and by
# hand from the repository root as `tests/update.sh`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$root/tests/fixtures/update" "$work/project"
chmod -R u+w "$work/project"
cd "$work/project"
export XDG_CACHE_HOME="$work/cache"

nix run "$root" -- update
if grep -q '"@std/path@1.0.0"' deno.lock; then
  echo "update: deno.lock still pins @std/path 1.0.0" >&2
  exit 1
fi
nix run "$root" -- prefetch
test "$(nix shell "$root" -c deno run main.ts)" = "a/b"
echo "update: both lockfiles were updated and pass the stale check"
