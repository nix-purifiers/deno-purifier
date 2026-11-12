#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run outside the Nix sandbox: native capture needs the local HTTP server.
# CI must leave DENO_NATIVE_LOCAL_SEED unset to prove a cold source fetch.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${DENO_NATIVE_RECEIPTS:-$(mktemp -d)}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
timeout --kill-after=5s 600s nix eval --impure --raw \
  --file "$root/tests/native-epochs.nix" currentVersion > "$work/current-version.stdout" 2> "$work/current-version.stderr"
current="$(cat "$work/current-version.stdout")"
for point in deno100 deno1463 deno206 current; do
  permission=()
  case "$point" in
    deno100) version=1.0.0 ;;
    deno1463) version=1.46.3 ;;
    deno206) version=2.0.6; permission=(--allow-import) ;;
    current) version="$current"; permission=(--allow-import) ;;
  esac
  timeout --kill-after=5s 600s nix build --impure --no-link --print-out-paths \
    --file "$root/tests/native-epochs.nix" "$point" > "$work/$point-build.stdout" 2> "$work/$point-build.stderr"
  cli="$(cat "$work/$point-build.stdout")"
  qualification=()
  if [ "${DENO_NATIVE_LOCAL_SEED:-0}" = 1 ]; then
    qualification=(--seed-source)
  fi
  python3 -B "$root/tests/native-epoch-lifecycle.py" \
    --cli "$cli/bin/deno-purifier" --version "$version" --work "$work/$point" \
    --redirect --empty-module --negative-cache "${permission[@]}" "${qualification[@]}"
done
printf 'Native epoch receipts: %s\n' "$work"
