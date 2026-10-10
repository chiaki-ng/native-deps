#!/usr/bin/env bash
# Build pinned dependencies from source for one darwin architecture.
#
#   scripts/build.sh <arch> [dep ...]
#
# Without dep names, builds everything. Each dep installs into its own
# prefix under out/<arch>/pool/<name>; a BUILD-INFO marker makes already
# built deps skippable (this is what the CI cache restores).

set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
source ./recipes.sh

[ "$(uname -s)" = Darwin ] || die "these builds must run on macOS"
[ $# -ge 1 ] || die "usage: build.sh <arch> [dep ...]"
ARCH=$1
shift
case "$ARCH" in
  arm64 | x86_64) ;;
  *) die "arch must be arm64 or x86_64" ;;
esac

need jq "brew install jq"
need cmake
need clang
xcrun -f clang >/dev/null 2>&1 || die "Xcode Command Line Tools not available"

MIN=$(config_get '.config.deployment_target')
WORK="$ROOT/out/$ARCH"
POOL="$WORK/pool"
mkdir -p "$POOL" "$WORK/srcs" "$WORK/build"

# Closure of requested deps (or all of them).
PLAN_FILE="$WORK/plan"
: >"$PLAN_FILE"
frontier="$*"
[ $# -gt 0 ] || frontier=$(all_dep_names | tr '\n' ' ')
while :; do
  next=""
  for n in $frontier; do
    [ -n "$n" ] || continue
    dep_exists "$n" || die "unknown dependency '$n' (not in the deps list of config/$PLATFORM.toml)"
    grep -qx -- "$n" "$PLAN_FILE" || printf '%s\n' "$n" >>"$PLAN_FILE"
    for d in $(dep_deps "$n"); do
      grep -qx -- "$d" "$PLAN_FILE" || next="$next $d"
    done
  done
  [ -n "$next" ] || break
  frontier=$next
done

write_build_info() { # write_build_info <name>
  local name=$1 xc
  xc=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
  jq -n \
    --arg name "$name" \
    --arg version "$(dep_get "$name" '.version')" \
    --arg sha256 "$(dep_get "$name" '.sha256')" \
    --arg kind "$(dep_get "$name" '.kind')" \
    --arg arch "$ARCH" \
    --arg deployment_target "$MIN" \
    --arg toolchain "$xc" \
    '{name: $name, version: $version, sha256: $sha256, kind: $kind,
      arch: $arch, deployment_target: $deployment_target, toolchain: $toolchain}' \
    >"$POOL/$name/BUILD-INFO"
}

# Build in dependency order.
ARCH_FLAGS="-arch $ARCH -mmacosx-version-min=$MIN -isysroot $(xcrun --show-sdk-path)"
ARCH_LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -f "$POOL/$name/BUILD-INFO" ]; then
    log "$name ($ARCH): already built, skipping"
    continue
  fi

  # Wire up the prefixes of everything this dep links against.
  DEP_CPPFLAGS=""
  DEP_LDFLAGS=""
  DEP_PKGCONFIG=""
  DEP_PREFIX_PATH=""
  for d in $(dep_deps "$name"); do
    [ -f "$POOL/$d/BUILD-INFO" ] || die "$name: dependency '$d' has not been built (cycle or ordering bug)"
    DEP_CPPFLAGS="$DEP_CPPFLAGS -I$POOL/$d/include"
    DEP_LDFLAGS="$DEP_LDFLAGS -L$POOL/$d/lib"
    DEP_PKGCONFIG="$DEP_PKGCONFIG:$POOL/$d/lib/pkgconfig"
    if [ -n "$DEP_PREFIX_PATH" ]; then DEP_PREFIX_PATH="$DEP_PREFIX_PATH:$POOL/$d"; else DEP_PREFIX_PATH="$POOL/$d"; fi
  done

  PREFIX="$POOL/$name"
  build_dep "$name"
  write_build_info "$name"
done < <(resolve_order | grep -Fx -f "$PLAN_FILE")

log "done: $(wc -l <"$PLAN_FILE" | tr -d ' ') dependency(ies) built for $ARCH"
