#!/usr/bin/env bash
# Publishes into the release that triggered this build ($RELEASE_TAG, set
# by the workflow to the release's tag):
#   - the downloaded, SHA-verified upstream source archive per pinned dep
#   - one build.tar.gz with every compiled dependency of every target (a
#     directory per library, macOS at the root and other targets under
#     <target>/, plus an internal SHA256SUMS covering every library file)
#   - build.tar.gz.sha256 (checksum of the tarball) and build.json
# The release's notes are replaced with the generated description (its
# title stays whatever its author set). Sources are always downloaded
# from the pinned upstream URLs — nothing is ever fetched from this
# repository's own releases.
#
#   scripts/publish-release.sh <dist-dir> <srcs-dir>
#   (needs gh with GH_TOKEN and RELEASE_TAG set; the description table is
#   read back out of the tarball)

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[ $# -eq 2 ] || die "usage: publish-release.sh <dist-dir> <srcs-dir>"
DISTDIR=$(cd "$1" && pwd)
SRCSDIR=$2
mkdir -p "$SRCSDIR"
shopt -s nullglob

need gh "https://cli.github.com/"
need jq "brew install jq"
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set"
[ -n "${RELEASE_TAG:-}" ] || die "RELEASE_TAG must be set to the tag of the release being published"

# --- verified source archives (downloaded from the pinned upstream URLs) ---
archives=""
for name in $(all_dep_names); do
  source=$(fetch_source "$name" "$SRCSDIR")
  if [ -d "$source" ]; then
    tar --exclude=.git -C "$(dirname "$source")" -czf "$source.tar.gz" "$(basename "$source")"
    source="$source.tar.gz"
  fi
  archives="$archives $source"
done

# --- the build archive and its checksum sidecar ---
POOLS=$(mktemp -d)
trap 'rm -rf "$POOLS"' EXIT
tarballs=""
for a in $(config_get '.config.architectures[]'); do
  build_tarball="$DISTDIR/$(tarball_name "$a")"
  [ -f "$build_tarball" ] || continue
  printf '%s  %s\n' "$(hash_file "$build_tarball")" "$(basename "$build_tarball")" >"$build_tarball.sha256"
  tarballs="$tarballs $build_tarball $build_tarball.sha256"
  mkdir -p "$POOLS/$a"
  tar -xf "$build_tarball" -C "$POOLS/$a"
done
[ -n "$tarballs" ] || die "no build tarball found in '$DISTDIR' — did assemble run?"
primary=$(primary_target)

# --- description table: library, compiled version, sha256 sums ---
# The table cell stays compact (file names, or a count for many-library
# deps like abseil); the full per-file checksums go into collapsible
# <details> blocks below the table, which GitHub renders.
rows=""
details=""
for d in "$POOLS"/*/ "$POOLS"/*/*/ "$POOLS"/*/*/*/; do
  info="$d/BUILD-INFO"
  [ -f "$info" ] || continue
  name=$(jq -r '.name' "$info")
  version=$(jq -r '.version' "$info")
  target=$(jq -r --arg p "$primary" '(.target // $p) + " " + .arch' "$info")
  if [ "$(jq -r '.commit // empty' "$info")" != "" ]; then
    src_cell="<code>$(jq -r '.repo' "$info")</code> $(jq -r '.ref' "$info")<br><code>$(jq -r '.commit' "$info")</code>"
  else
    src_cell="<code>$(dep_source_name "$name")</code><br><code>$(jq -r '.sha256' "$info")</code>"
  fi
  src_cell="$src_cell$(jq -r '(.patches // [])[] | "<br>patch <code>\(.file)</code> <code>\(.sha256)</code>"' "$info" | tr -d '\n')"
  names=""
  sums=""
  nlibs=0
  for a in "$d"/lib/*.a "$d"/lib/*.dylib "$d"/lib/*.so "$d"/lib/*.so.* "$d"/lib/*.lib "$d"/bin/*.dll; do
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
  rows="$rows| $name | $target | $version | $src_cell | $names"$'\n'
  if [ -n "$sums" ]; then
    details="$details<details><summary><code>$name</code> ($target) — $nlibs file(s)</summary>"$'\n\n'"$sums"$'\n'"</details>"$'\n'
  fi
done
[ -n "$rows" ] || die "no built dependencies found in$tarballs"

# --- build environment details for the notes ---
runner="local machine"
[ -n "${ImageOS:-}" ] && runner="GitHub Actions ($ImageOS${ImageVersion:+ image $ImageVersion})"
revision=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unversioned)
infos=$(find "$POOLS" -name BUILD-INFO)
target_archs=$(for i in $infos; do jq -r '.arch' "$i"; done | sort -u | tr '\n' ' ' | sed 's/ *$//')
targets=$(for i in $infos; do jq -r --arg p "$primary" '.target // $p' "$i"; done | sort -u | tr '\n' ' ' | sed 's/ *$//')

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
  toolchain_release_notes "$POOLS"
  echo "| Architectures | $target_archs |"
  echo "| Targets | $targets |"
  echo
  echo "## Libraries"
  echo
  echo "All compiled dependencies ship as $(for t in $tarballs; do case "$t" in *.sha256) ;; *) printf '`%s` ' "$(basename "$t")" ;; esac; done)(one per architecture), $primary at the root and every other target under \`<target>/\`, containing a directory per library (\`include/\` + \`lib/\` + \`bin/\` + \`BUILD-INFO\` provenance) and a root \`SHA256SUMS\` covering every library file — verify after extraction with \`sha256sum -c SHA256SUMS\`. Each tarball's own checksum is published alongside it as \`<tarball>.sha256\`."
  echo
  echo "| Library | Target | Compiled version | Source archive · sha256 | Libraries |"
  echo "| --- | --- | --- | --- | --- |"
  printf '%s' "$rows"
  echo
  echo "### Per-file checksums"
  echo
  printf '%s' "$details"
  echo
  echo "Source archives match the SHA-256 pins in \`deps/\`; machine-readable build metadata (resolved versions, per-dependency toolchains) is in \`build.json\`."
} >"$notes"

gh release view "$RELEASE_TAG" >/dev/null 2>&1 \
  || die "release '$RELEASE_TAG' does not exist — publish is triggered by releasing it"
gh release edit "$RELEASE_TAG" --notes-file "$notes"
# shellcheck disable=SC2086
gh release upload "$RELEASE_TAG" $archives $tarballs "$DISTDIR/build.json" --clobber
log "release $RELEASE_TAG updated with sources, the build tarball, checksums and metadata"
