#!/usr/bin/env bash

toolchain_architectures() { printf '%s\n' arm64 x86_64; }

toolchain_check_config() {
  config_get '.config.deployment_target' | grep -qE '^[0-9]+\.[0-9]+$' \
    || die "config/$PLATFORM.toml: deployment_target must look like 26.0"
  jq -e '.config.targets | to_entries | all((.value.sdk | type) == "string" and (.value.minimum_flag | type) == "string")' \
    "$(_manifest_json)" >/dev/null || die "config/$PLATFORM.toml: every target needs string sdk and minimum_flag"
}

toolchain_id() { xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

toolchain_setup() {
  local xc_all xc_line xc_major
  [ "$(uname -s)" = Darwin ] || die "these builds must run on macOS"
  need cmake
  need clang
  xcrun -f clang >/dev/null 2>&1 || die "Xcode Command Line Tools not available"
  # The pin: Xcode 26 or newer — the toolchain floor for targeting macOS 26.
  # The macos-26 runner image's default Xcode qualifies; locally whatever
  # xcode-select points at (e.g. Xcode 27 on macOS 27) does too.
  xc_all=$(xcodebuild -version 2>/dev/null || true)
  xc_line=${xc_all%%$'\n'*}
  xc_major=${xc_line#Xcode }
  xc_major=${xc_major%%.*}
  case "$xc_major" in
    '' | *[!0-9]*) die "cannot parse Xcode version from '${xc_line:-none}'" ;;
  esac
  [ "$xc_major" -ge 26 ] || die "Xcode 26+ required (the macOS 26 toolchain); found: $xc_line"

  MIN=$(config_get '.config.deployment_target')
  SDK_NAME=$(target_get '.sdk')
  MIN_FLAG=$(target_get '.minimum_flag')
  SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path) || die "SDK '$SDK_NAME' is not installed"
  CC=clang
  CXX=clang++
  MESON_SYSTEM=darwin
  case "$ARCH" in arm64) MESON_CPU_FAMILY=aarch64 ;; *) MESON_CPU_FAMILY=$ARCH ;; esac
  ARCH_FLAGS="-arch $ARCH $MIN_FLAG=$MIN -isysroot $SDK_PATH"
  ARCH_LDFLAGS="-arch $ARCH $MIN_FLAG=$MIN"
  [ "$TARGET" = macos ] || ARCH_LDFLAGS="$ARCH_LDFLAGS -isysroot $SDK_PATH"
  HOST_PKGCONFIG=""
  HOST_TRIPLE="$ARCH-apple-darwin"
  OPENSSL_TARGET="darwin64-$ARCH-cc"
}

toolchain_cross() { [ "$(uname -m)" != "$1" ] || [ "$TARGET" != macos ]; }

toolchain_cmake_args() {
  local system
  printf -- '-DCMAKE_OSX_ARCHITECTURES=%s -DCMAKE_OSX_DEPLOYMENT_TARGET=%s -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local ' "$ARCH" "$MIN"
  system=$(target_get '.cmake_system_name // empty')
  if [ -n "$system" ]; then
    printf -- '-DCMAKE_SYSTEM_NAME=%s -DCMAKE_OSX_SYSROOT=%s -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH' "$system" "$SDK_NAME"
  elif toolchain_cross "$ARCH"; then
    printf -- '-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=%s' "$ARCH"
  fi
}

toolchain_host_cmake_args() { printf -- '-DCMAKE_OSX_ARCHITECTURES=%s -DCMAKE_OSX_DEPLOYMENT_TARGET=%s' "$(uname -m)" "$MIN"; }

toolchain_meson_args() { printf -- '-Db_staticpic=true'; }

toolchain_dep_ldflags() { printf -- '-L%s' "$1"; }

toolchain_release_notes() {
  echo "| Xcode | $(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//') |"
  echo "| macOS SDK | $(xcrun --show-sdk-version 2>/dev/null) |"
  echo "| Compiler | $(/usr/bin/clang --version 2>/dev/null | sed -n '1p') |"
  echo "| CMake | $(cmake --version 2>/dev/null | sed -n '1p') |"
  echo "| Minimum OS | $(config_get '.config.deployment_target') |"
}
