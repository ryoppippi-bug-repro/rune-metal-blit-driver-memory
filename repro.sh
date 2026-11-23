#!/bin/bash
# Builds Rune's examples/hello at the pinned commit with the patch applied, then prints its
# peak physical footprint for `--snap`: once as Rune ships (blits), once with RUNE_NOBLIT=1.
set -euo pipefail
RUNE_REV=86b903de7fef9c6b683e05dc23440de4ebbc4347
here=$(cd "$(dirname "$0")" && pwd)
work=$here/work
if [ ! -d "$work/rune" ]; then
  git clone --quiet https://github.com/anomalyco/rune "$work/rune"
  git -C "$work/rune" checkout --quiet "$RUNE_REV"
  git -C "$work/rune" apply "$here/rune-cpu-uploads.patch"
fi
cargo build --quiet --release --manifest-path "$work/rune/Cargo.toml" -p hello --features rune/tooling
hello=$work/rune/target/release/hello

peak() {
  /usr/bin/time -l "$hello" --snap "$work/hello.png" --scene on 2>&1 >/dev/null |
    awk '/peak memory footprint/ { printf "%.0f MB\n", $1 / 1e6 }'
}
echo "hello --snap, Rune as shipped:      $(peak)"
echo "hello --snap, RUNE_NOBLIT=1:        $(RUNE_NOBLIT=1 peak)"
