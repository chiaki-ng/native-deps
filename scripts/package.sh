#!/usr/bin/env bash
# Package all built dependencies as one archive.
#
#   scripts/package.sh <arch> <pool-dir> <dist-dir>
#
# Produces <dist-dir>/build.tar.gz containing:
#   <name>/…        one directory per dependency (include/ + lib/ + bin/,
#                   plus its BUILD-INFO provenance marker)
#   SHA256SUMS      sha256 of every library artifact (*.a, *.dylib; real
#                   files, symlinks skipped), relative to the archive root,
#                   so `sha256sum -c SHA256SUMS` works after extraction
# plus build-<arch>.json describing the build.
#
# Note: the fixed name assumes one architecture per publish (the current
# config); if a second architecture is ever enabled, give this an arch
# suffix and upload one per architecture.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[ $# -eq 3 ] || die "usage: package.sh <arch> <pool-dir> <dist-dir>"
ARCH=$1
POOLDIR=$(cd "$2" && pwd)
DISTDIR=$3
mkdir -p "$DISTDIR"

need jq "brew install jq"
command -v rsync >/dev/null 2>&1 || die "rsync not found"
shopt -s nullglob

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

names=""
count=0
for d in "$POOLDIR"/*/; do
  name=$(basename "$d")
  info="$d/BUILD-INFO"
  [ -f "$info" ] || die "pool entry '$name' has no BUILD-INFO — malformed artifact?"
  rsync -a "${d%/}" "$STAGE/"
  rm -rf "$STAGE/$name/share/man" "$STAGE/$name/share/doc"
  names="$names $name"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "pool '$POOLDIR' is empty — nothing to package"

# Checksums for every library artifact inside the archive, relative to its root.
(
  cd "$STAGE"
  : >SHA256SUMS
  find . -type f \( -name '*.a' -o -name '*.dylib' \) | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(hash_file "$f")" "${f#./}"
  done >SHA256SUMS
)

# shellcheck disable=SC2086
tar -C "$STAGE" -czf "$DISTDIR/build.tar.gz" SHA256SUMS $names
log "packaged $DISTDIR/build.tar.gz ($count dependencies)"

rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)
deps_json="[]"
if ls "$POOLDIR"/*/BUILD-INFO >/dev/null 2>&1; then
  deps_json=$(jq -s '.' "$POOLDIR"/*/BUILD-INFO)
fi
jq -n \
  --arg arch "$ARCH" \
  --arg revision "$rev" \
  --arg deployment_target "$(config_get '.config.deployment_target')" \
  --argjson deps "$deps_json" \
  '{arch: $arch, revision: $revision, deployment_target: $deployment_target, deps: $deps}' \
  >"$DISTDIR/build-$ARCH.json"
