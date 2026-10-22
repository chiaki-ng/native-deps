#!/usr/bin/env bash

toolchain_architectures() { printf '%s\n' aarch64; }

toolchain_check_config() {
  jq -e '.config.toolchain | (.image | type) == "string" and (.gcc | type) == "string"
           and (.packages | type) == "array" and (.packages | all(type == "string"))
           and (.dkp_packages | type) == "array" and (.dkp_packages | all(type == "string"))' \
    "$(_manifest_json)" >/dev/null || die "config/$PLATFORM.toml: [toolchain] needs string image and gcc and packages and dkp_packages lists"
  config_get '.config.toolchain.gcc' | grep -qE '^[0-9]+$' \
    || die "config/$PLATFORM.toml: toolchain.gcc must be a major version like 16"
}

toolchain_gcc() { printf '%s/devkitA64/bin/aarch64-none-elf-gcc' "${DEVKITPRO:-/opt/devkitpro}"; }

toolchain_id() {
  printf 'devkitA64 gcc %s libnx %s cmake %s' \
    "$("$(toolchain_gcc)" -dumpfullversion 2>/dev/null)" \
    "$(dkp-pacman -Q libnx 2>/dev/null | cut -d' ' -f2)" \
    "$(cmake --version 2>/dev/null | sed -n '1s/^cmake version //p')"
}

toolchain_setup() {
  local tool wanted_gcc bin
  [ "$(uname -s)" = Linux ] || die "nx builds must run on Linux, inside $(config_get '.config.toolchain.image')"
  [ "$ARCH" = aarch64 ] || die "nx builds target aarch64 only"
  DEVKITPRO=${DEVKITPRO:-/opt/devkitpro}
  [ -d "$DEVKITPRO/libnx" ] || die "libnx not found under $DEVKITPRO; build inside $(config_get '.config.toolchain.image')"
  for tool in make cmake ninja python3 perl patch git; do need "$tool"; done
  bin="$DEVKITPRO/devkitA64/bin"
  export PATH="$bin:$PATH"
  [ -x "$(toolchain_gcc)" ] || die "aarch64-none-elf-gcc not found in $bin"
  wanted_gcc=$(config_get '.config.toolchain.gcc')
  [ "$("$(toolchain_gcc)" -dumpversion | cut -d. -f1)" = "$wanted_gcc" ] \
    || die "devkitA64 gcc $("$(toolchain_gcc)" -dumpfullversion) found but the pin is gcc $wanted_gcc; update devkitA64 with dkp-pacman"

  MIN=""
  SDK_NAME=""
  SDK_PATH=""
  MIN_FLAG=""
  CC="$bin/aarch64-none-elf-gcc"
  CXX="$bin/aarch64-none-elf-g++"
  MESON_SYSTEM=horizon
  MESON_CPU_FAMILY=aarch64
  ARCH_FLAGS="-march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIE -ffunction-sections -fdata-sections -D__SWITCH__ -isystem $DEVKITPRO/libnx/include -isystem $DEVKITPRO/portlibs/switch/include -O2"
  ARCH_LDFLAGS="-specs=$DEVKITPRO/libnx/switch.specs -L$DEVKITPRO/libnx/lib -L$DEVKITPRO/portlibs/switch/lib"
  HOST_TRIPLE=aarch64-none-elf
  HOST_PKGCONFIG="$DEVKITPRO/portlibs/switch/lib/pkgconfig"
  OPENSSL_TARGET=""
  OPENSSL_FLAGS=""
}

toolchain_cross() { return 0; }

toolchain_cmake_args() {
  printf -- '-G Ninja -DCMAKE_TOOLCHAIN_FILE=%s/cmake/Switch.cmake -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH' "${DEVKITPRO:-/opt/devkitpro}"
}

toolchain_host_cmake_args() { :; }

toolchain_meson_args() { :; }

toolchain_dep_ldflags() { printf -- '-L%s' "$1"; }

toolchain_release_notes() {
  local pools=$1
  echo "| Container | \`$(config_get '.config.toolchain.image')\` |"
  echo "| GCC | $(config_get '.config.toolchain.gcc') |"
  echo "| Toolchain | $(for i in "$pools"/*/BUILD-INFO "$pools"/*/*/BUILD-INFO "$pools"/*/*/*/BUILD-INFO; do [ -f "$i" ] && jq -r '.toolchain' "$i"; done | sort -u | paste -s -d';' - | sed 's/;/<br>/g') |"
}
