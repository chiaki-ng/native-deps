#!/usr/bin/env bash
# Publish one rolling release (`sources`) holding, for every pinned dep:
#   - the downloaded, SHA-verified upstream source archive
#   - the per-dependency build archive from the assemble jobs:
#       <name>-<version>-darwin-<arch>.tar.gz  (that dep's include/ + lib/ + bin/)
#   - SHA256SUMS (every uploaded file) and build.json (resolved versions)
# The release description is regenerated as a table listing each library,
# its compiled version and the sha256 sums of its sources and libraries.
#
#   scripts/publish-release.sh <dist-dir> <srcs-dir> <pool-dir>
#   (needs gh with GH_TOKEN set; the pool is used for the description table)

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[ $# -eq 3 ] || die "usage: publish-release.sh <dist-dir> <srcs-dir> <pool-dir>"
DISTDIR=$(cd "$1" && pwd)
SRCSDIR=$2
POOLDIR=$3
mkdir -p "$SRCSDIR"
shopt -s nullglob

need gh "https://cli.github.com/"
need jq "brew install jq"
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set"

# --- verified source archives (downloaded from the pinned upstream URLs) ---
archives=""
for name in $(all_dep_names); do
  archives="$archives $(fetch_source "$name" "$SRCSDIR")"
done

# --- per-dependency build archives ---
tarballs=""
for f in "$DISTDIR"/*.tar.*; do
  tarballs="$tarballs $f"
done
[ -n "$tarballs" ] || die "no packaged dependency archives found in '$DISTDIR'"

# --- description table: library, compiled version, sha256 sums ---
rows=""
for d in "$POOLDIR"/*/; do
  info="$d/BUILD-INFO"
  [ -f "$info" ] || continue
  name=$(jq -r '.name' "$info")
  version=$(jq -r '.version' "$info")
  arch=$(jq -r '.arch' "$info")
  src_sha=$(jq -r '.sha256' "$info")
  src_file=$(basename "$(resolve_url "$(dep_get "$name" '.url')" "$version" "$name")")
  libs=""
  for a in "$d"/lib/*.a; do
    [ -e "$a" ] || continue
    libs="$libs<code>$(basename "$a")</code> <code>$(hash_file "$a")</code><br>"
  done
  [ -n "$libs" ] || libs="<em>no static libraries</em>"
  rows="$rows| $name | $version | <code>$src_file</code><br><code>$src_sha</code> | $libs"$'\n'
done
[ -n "$rows" ] || die "no built dependencies found in pool '$POOLDIR'"

# --- SHA256SUMS over every file being uploaded ---
sums="$DISTDIR/SHA256SUMS"
: >"$sums"
for f in $archives $tarballs; do
  printf '%s  %s\n' "$(hash_file "$f")" "$(basename "$f")" >>"$sums"
done

# --- release description ---
notes=$(mktemp)
{
  echo "Pinned dependencies built from source for darwin ($(uname -m) runner, minimum macOS $(config_get '.config.deployment_target'))."
  echo
  echo "Each library ships as \`<name>-<version>-darwin-<arch>.tar.gz\` (its \`include/\` + \`lib/\` + \`bin/\`), next to its verified upstream source archive."
  echo
  echo "| Library | Compiled version | Source archive · sha256 | Built static libraries · sha256 |"
  echo "| --- | --- | --- | --- |"
  printf '%s' "$rows"
  echo
  echo "Verify any download against \`SHA256SUMS\`; machine-readable build metadata (resolved versions, toolchain) is in \`build.json\`."
} >"$notes"

log "creating sources release if missing"
gh release view sources >/dev/null 2>&1 \
  || gh release create sources --title "Pinned dependencies: sources and darwin builds" --notes-file "$notes"
gh release edit sources --title "Pinned dependencies: sources and darwin builds" --notes-file "$notes"

# shellcheck disable=SC2086
gh release upload sources $archives $tarballs "$sums" "$DISTDIR/build.json" --clobber
log "sources release updated with archives and per-dependency builds"
