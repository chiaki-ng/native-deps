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
# The table cell stays compact (file names, or a count for many-library
# deps like abseil); the full per-file checksums go into collapsible
# <details> blocks below the table, which GitHub renders.
rows=""
details=""
for d in "$POOLDIR"/*/; do
  info="$d/BUILD-INFO"
  [ -f "$info" ] || continue
  name=$(jq -r '.name' "$info")
  version=$(jq -r '.version' "$info")
  arch=$(jq -r '.arch' "$info")
  src_sha=$(jq -r '.sha256' "$info")
  src_file=$(basename "$(resolve_url "$(dep_get "$name" '.url')" "$version" "$name")")
  names=""
  sums=""
  nlibs=0
  for a in "$d"/lib/*.a "$d"/lib/*.dylib; do
    [ -e "$a" ] || continue
    [ -L "$a" ] && continue # skip unversioned/version symlinks; hash the real file
    nlibs=$((nlibs + 1))
    if [ "$nlibs" -le 6 ]; then
      [ -n "$names" ] && names="$names · "
      names="$names$(basename "$a")"
    fi
    sums="$sums$(hash_file "$a")  $(basename "$a")"$'\n'
  done
  [ "$nlibs" -gt 6 ] && names="$nlibs libraries"
  [ -n "$names" ] || names="<em>none</em>"
  rows="$rows| $name | $version | <code>$src_file</code><br><code>$src_sha</code> | $names"$'\n'
  if [ -n "$sums" ]; then
    details="$details<details><summary><code>$name</code> — $nlibs file(s)</summary>"$'\n\n'"$sums"$'\n'"</details>"$'\n'
  fi
done
[ -n "$rows" ] || die "no built dependencies found in pool '$POOLDIR'"

# --- SHA256SUMS over every file being uploaded ---
sums="$DISTDIR/SHA256SUMS"
: >"$sums"
for f in $archives $tarballs; do
  printf '%s  %s\n' "$(hash_file "$f")" "$(basename "$f")" >>"$sums"
done

# --- build environment details for the notes ---
runner="local machine"
[ -n "${ImageOS:-}" ] && runner="GitHub Actions ($ImageOS${ImageVersion:+ image $ImageVersion})"
xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
sdk=$(xcrun --show-sdk-version 2>/dev/null)
clang=$(/usr/bin/clang --version 2>/dev/null | sed -n '1p')
cmake=$(cmake --version 2>/dev/null | sed -n '1p')
revision=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)
target_archs=$(for i in "$POOLDIR"/*/BUILD-INFO; do jq -r '.arch' "$i"; done | sort -u | tr '\n' ' ' | sed 's/ *$//')

# --- release description ---
notes=$(mktemp)
{
  echo "Pinned dependencies built from source, from the deps/ pins at revision \`$revision\`."
  echo
  echo "## Build environment"
  echo
  echo "| | |"
  echo "| --- | --- |"
  echo "| Revision | \`$revision\` |"
  echo "| Built on | $runner |"
  echo "| Xcode | $xcode |"
  echo "| macOS SDK | $sdk |"
  echo "| Compiler | $clang |"
  echo "| CMake | $cmake |"
  echo "| Architectures | $target_archs |"
  echo "| Minimum macOS | $(config_get '.config.deployment_target') |"
  echo
  echo "## Libraries"
  echo
  echo "Each library ships as \`<name>-<version>-darwin-<arch>.tar.gz\` (its \`include/\` + \`lib/\` + \`bin/\`), next to its verified upstream source archive."
  echo
  echo "| Library | Compiled version | Source archive · sha256 | Libraries |"
  echo "| --- | --- | --- | --- |"
  printf '%s' "$rows"
  echo
  echo "### Per-file checksums"
  echo
  printf '%s' "$details"
  echo
  echo "Verify any download against \`SHA256SUMS\`; machine-readable build metadata (resolved versions, per-dependency toolchains) is in \`build.json\`."
} >"$notes"

log "creating sources release if missing"
gh release view sources >/dev/null 2>&1 \
  || gh release create sources --title "Pinned dependencies: sources and darwin builds" --notes-file "$notes"
gh release edit sources --title "Pinned dependencies: sources and darwin builds" --notes-file "$notes"

# shellcheck disable=SC2086
gh release upload sources $archives $tarballs "$sums" "$DISTDIR/build.json" --clobber
log "sources release updated with archives and per-dependency builds"
