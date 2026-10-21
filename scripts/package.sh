#!/usr/bin/env bash
# Package the built dependencies of every target as one archive.
#
#   scripts/package.sh <arch> <out-dir> <dist-dir>
#
# <out-dir> holds one pool per target, laid out as build.sh writes them:
# <out-dir>/<arch>/pool for macOS and <out-dir>/<arch>-<target>/pool for
# the others. Targets without a pool are left out.
#
# Produces <dist-dir>/build.tar.gz containing:
#   <name>/…           one directory per macOS dependency (include/ + lib/ +
#                      bin/, plus its BUILD-INFO provenance marker)
#   <target>/<name>/…  the same per dependency for every other target
#   SHA256SUMS         sha256 of every library artifact (*.a, *.dylib; real
#                      files, symlinks skipped), relative to the archive root,
#                      so `sha256sum -c SHA256SUMS` works after extraction
# plus build-<arch>.json describing the build.
#
# Note: the fixed name assumes one architecture per publish (the current
# config); if a second architecture is ever enabled, give this an arch
# suffix and upload one per architecture.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[ $# -eq 3 ] || die "usage: package.sh <arch> <out-dir> <dist-dir>"
ARCH=$1
OUTDIR=$(cd "$2" && pwd)
DISTDIR=$3
mkdir -p "$DISTDIR"

need jq "brew install jq"
command -v rsync >/dev/null 2>&1 || die "rsync not found"
shopt -s nullglob

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

primary=$(primary_target)
tarball=$(tarball_name "$ARCH")
roots=""
count=0
targets_json="{}"
for target in $(all_target_names); do
  pool="$OUTDIR/$(pool_slug "$ARCH" "$target")/pool"
  [ -d "$pool" ] || continue
  dest="$STAGE"
  [ "$target" = "$primary" ] || dest="$STAGE/$target"
  mkdir -p "$dest"
  built=0
  for d in "$pool"/*/; do
    name=$(basename "$d")
    info="$d/BUILD-INFO"
    [ -f "$info" ] || die "pool entry '$name' ($target) has no BUILD-INFO — malformed artifact?"
    rsync -a "${d%/}" "$dest/"
    rm -rf "$dest/$name/share/man" "$dest/$name/share/doc"
    find "$dest/$name/bin" -type f -exec chmod u+x,g+x,o+x {} + 2>/dev/null || true
    find "$dest/$name/lib" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.dll' \) -exec chmod u+x,g+x,o+x {} + 2>/dev/null || true
    [ "$target" != "$primary" ] || roots="$roots $name"
    built=$((built + 1))
  done
  [ "$built" -gt 0 ] || die "pool '$pool' is empty — nothing to package"
  [ "$target" = "$primary" ] || roots="$roots $target"
  targets_json=$(jq -s --arg target "$target" --argjson all "$targets_json" '$all + {($target): .}' "$pool"/*/BUILD-INFO)
  count=$((count + built))
done
[ "$count" -gt 0 ] || die "no pools for $ARCH under '$OUTDIR' — nothing to package"

# Checksums for every library artifact inside the archive, relative to its root.
(
  cd "$STAGE"
  : >SHA256SUMS
  library_files . | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(hash_file "$f")" "${f#./}"
  done >SHA256SUMS
)

# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$DISTDIR/$tarball" SHA256SUMS $roots
log "packaged $DISTDIR/$tarball ($count dependencies across $(printf '%s' "$targets_json" | jq -r 'keys | join(", ")'))"

rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)
jq -n \
  --arg arch "$ARCH" \
  --arg revision "$rev" \
  --arg platform "$PLATFORM" \
  --arg tarball "$tarball" \
  --arg deployment_target "$(config_get '.config.deployment_target // .config.toolchain.glibc // empty')" \
  --arg primary "$primary" \
  --argjson targets "$targets_json" \
  '{platform: $platform, arch: $arch, tarball: $tarball, revision: $revision, deployment_target: $deployment_target,
    deps: ($targets[$primary] // []), targets: $targets}' \
  >"$DISTDIR/build-$ARCH.json"
