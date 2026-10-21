#!/usr/bin/env bash
# Build pinned dependencies from source for one darwin architecture and
# target (TARGET=macos|ios|ios-simulator, default macos).
#
#   scripts/build.sh <arch> [dep ...]
#
# Without dep names, builds everything. Each dep installs into its own
# prefix under out/<arch>/pool/<name> (out/<arch>-<target> off macOS); a BUILD-INFO marker makes already
# built deps skippable (this is what the CI cache restores).

set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
source ./recipes.sh

[ $# -ge 1 ] || die "usage: build.sh <arch> [dep ...]"
ARCH=$1
shift
toolchain_architectures | grep -qx -- "$ARCH" || die "arch must be one of: $(toolchain_architectures | paste -s -d' ' -)"

need jq "brew install jq"
[ -n "$TARGET" ] || TARGET=$(primary_target)
target_exists "$TARGET" || die "unknown target '$TARGET' (not in the targets of config/$PLATFORM.toml)"
toolchain_setup
WORK="$ROOT/out/$(pool_slug "$ARCH" "$TARGET")"
POOL="$WORK/pool"
mkdir -p "$POOL" "$WORK/srcs" "$WORK/build"

# Closure of requested deps (or all of them).
PLAN_FILE="$WORK/plan"
: >"$PLAN_FILE"
frontier="$*"
[ $# -gt 0 ] || frontier=$(for n in $(all_dep_names); do if dep_enabled "$n"; then printf '%s ' "$n"; fi; done)
while :; do
  next=""
  for n in $frontier; do
    [ -n "$n" ] || continue
    dep_exists "$n" || die "unknown dependency '$n' (not in the deps list of config/$PLATFORM.toml)"
    dep_enabled "$n" || die "dependency '$n' is not built for $ARCH (see architectures in deps/$n/$PLATFORM.toml)"
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
  xc=$(toolchain_id)
  jq -n \
    --arg name "$name" \
    --argjson pin "$(dep_json "$name")" \
    --argjson patches "$(dep_patches_json "$name")" \
    --arg arch "$ARCH" \
    --arg target "$TARGET" \
    --arg deployment_target "$MIN" \
    --arg toolchain "$xc" \
    '{name: $name, version: $pin.version, sha256: ($pin.sha256 // null),
      repo: ($pin.repo // null), ref: ($pin.ref // null), commit: ($pin.commit // null),
      patches: $patches, kind: $pin.kind,
      arch: $arch, target: $target, deployment_target: $deployment_target, toolchain: $toolchain}' \
    >"$POOL/$name/BUILD-INFO"
}

# Build in dependency order.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -f "$POOL/$name/BUILD-INFO" ]; then
    # Built with a different toolchain (e.g. local pool after an Xcode
    # upgrade)? Rebuild instead of serving the stale entry.
    current_xc=$(toolchain_id)
    built_xc=$(jq -r '.toolchain' "$POOL/$name/BUILD-INFO")
    if [ "$built_xc" = "$current_xc" ]; then
      log "$name ($ARCH $TARGET): already built, skipping"
      continue
    fi
    log "$name ($ARCH $TARGET): built with '$built_xc' but toolchain is '$current_xc' — rebuilding"
    rm -rf "$POOL/$name"
  fi

  # Wire up the prefixes of everything this dep links against.
  DEP_CPPFLAGS=""
  DEP_LDFLAGS=""
  DEP_PKGCONFIG=""
  DEP_PREFIX_PATH=""
  for d in $(dep_closure "$name"); do
    [ -f "$POOL/$d/BUILD-INFO" ] || die "$name: dependency '$d' has not been built (cycle or ordering bug)"
    DEP_CPPFLAGS="$DEP_CPPFLAGS -I$POOL/$d/include"
    DEP_LDFLAGS="$DEP_LDFLAGS $(toolchain_dep_ldflags "$POOL/$d/lib")"
    DEP_PKGCONFIG="$DEP_PKGCONFIG:$POOL/$d/lib/pkgconfig"
    if [ -n "$DEP_PREFIX_PATH" ]; then DEP_PREFIX_PATH="$DEP_PREFIX_PATH:$POOL/$d"; else DEP_PREFIX_PATH="$POOL/$d"; fi
  done

  PREFIX="$POOL/$name"
  build_dep "$name"
  write_build_info "$name"
done < <(resolve_order | grep -Fx -f "$PLAN_FILE")

log "done: $(wc -l <"$PLAN_FILE" | tr -d ' ') dependency(ies) built for $ARCH $TARGET"
