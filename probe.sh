#!/bin/bash
# Bare Metal, no Rune: what the driver charges for each kind of encoder.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/work"
swiftc -O "$here/probe.swift" -o "$here/work/probe"
for steps in "render" "blit" "compute" "replace" "replace render" "render render blit blit" "render blit idle render"; do
  echo "== $steps"
  # shellcheck disable=SC2086
  "$here/work/probe" $steps
done
