#!/usr/bin/env bash
# Merge two single-arch prefixes (arm64 + x86_64) into a universal one.
# Mach-O files in bin/, lib/ and libexec/ are lipo'd together; headers and
# everything else come from the first prefix.
#
#   scripts/make-universal.sh <prefix-arm64> <prefix-x86_64> <out-prefix>

set -euo pipefail
source "$(dirname "$0")/common.sh"

[ $# -eq 3 ] || die "usage: make-universal.sh <prefix-arm64> <prefix-x86_64> <out-prefix>"
A=$(cd "$1" && pwd)
B=$(cd "$2" && pwd)
OUT=$3

command -v lipo >/dev/null 2>&1 || die "lipo not found (run on macOS)"
rm -rf "$OUT"
ditto "$A" "$OUT"

merged=0
for dir in bin lib libexec; do
  [ -d "$B/$dir" ] || continue
  while IFS= read -r -d '' f; do
    rel=${f#"$B"/}
    if [ -e "$A/$rel" ]; then
      # lipo -info succeeds only on Mach-O; skip text files (.la, .pc, cmake configs)
      if lipo -info "$A/$rel" >/dev/null 2>&1 && lipo -info "$f" >/dev/null 2>&1; then
        lipo -create -output "$OUT/$rel.universal" "$A/$rel" "$f"
        mv "$OUT/$rel.universal" "$OUT/$rel"
        merged=$((merged + 1))
      fi
    else
      mkdir -p "$(dirname "$OUT/$rel")"
      ditto "$f" "$OUT/$rel"
    fi
  done < <(find "$B/$dir" -type f -print0)
done
log "universal prefix at $OUT ($merged Mach-O file(s) lipo'd)"
