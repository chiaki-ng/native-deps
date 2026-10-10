#!/usr/bin/env bash
# Per-kind build recipes. Sourced by build.sh, which sets:
#   ARCH ARCH_FLAGS ARCH_LDFLAGS MIN PREFIX POOL WORK
#   DEP_CPPFLAGS DEP_LDFLAGS DEP_PKGCONFIG DEP_PREFIX_PATH  (from depends_on)
# Expects common.sh to already be sourced.
#
# The cmake recipe mirrors the hermetic setup of chiaki-native-main's
# Tools/Dependencies/build.py: PIC static libs, libdir=lib, and package
# lookup fenced off from Homebrew and the cmake registry so builds only
# ever see the pinned pool.

# Expand tokens in manifest flags: @ARCH@ -> target arch, @POOL@ -> dep pool root.
expand_tokens() { printf '%s' "$1" | sed -e "s/@ARCH@/$ARCH/g" -e "s|@POOL@|$POOL|g"; }

recipe_cmake() { # recipe_cmake <name> <srcdir>
  local name=$1 srcdir=$2 b="$2/ci-build" opts kv crossargs depargs shared extra=""
  opts=$(dep_get "$name" '.cmake_options // {} | to_entries[] | "\(.key)=\(.value)"' | while IFS= read -r kv; do printf -- '-D%s ' "$kv"; done)
  if [ "$(dep_get "$name" '.shared // false')" = true ]; then shared=ON; else shared=OFF; fi
  crossargs=""
  if is_cross "$ARCH"; then crossargs="-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=$ARCH"; fi
  depargs=""
  [ -n "$DEP_PREFIX_PATH" ] && depargs="-DCMAKE_PREFIX_PATH=$DEP_PREFIX_PATH"

  # protobuf cross builds need a protoc that runs on the build host: build a
  # native one first, then build only the libraries for the target arch.
  if [ "$name" = protobuf ] && is_cross "$ARCH"; then
    log "protobuf: building host protoc ($(uname -m)) for cross-compilation"
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      cmake -S "$srcdir" -B "$srcdir/host-build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$srcdir/host-prefix" \
      -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
      -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_PROTOC_BINARIES=ON >/dev/null
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      cmake --build "$srcdir/host-build" --target protoc -j "$(njobs)"
    extra="-Dprotobuf_BUILD_PROTOC_BINARIES=OFF -DProtobuf_PROTOC_EXECUTABLE=$srcdir/host-build/protoc"
  fi

  env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    cmake -S "$srcdir" -B "$b" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=$shared \
    -DBUILD_TESTING=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    $crossargs $depargs $extra $opts
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake --build "$b" -j "$(njobs)"
  cmake --install "$b"
}

recipe_configure() { # recipe_configure <name> <srcdir>
  local name=$1 srcdir=$2 b="$2/ci-build" flags="" f hostarg="" crossflags="" linkage
  while IFS= read -r f; do flags="$flags$(expand_tokens "$f") "; done \
    <<<"$(dep_get "$name" '(.configure_flags // [])[]')"
  if [ "$(dep_get "$name" '.shared // false')" = true ]; then
    linkage="--enable-shared --disable-static"
  else
    linkage="--enable-static --disable-shared"
  fi
  if is_cross "$ARCH"; then
    hostarg="--host=$ARCH-apple-darwin"
    while IFS= read -r f; do crossflags="$crossflags$(expand_tokens "$f") "; done \
      <<<"$(dep_get "$name" '(.cross_configure_flags // [])[]')"
  fi
  mkdir -p "$b"
  (
    cd "$b"
    env CC=clang CXX=clang++ \
      CFLAGS="$ARCH_FLAGS" CXXFLAGS="$ARCH_FLAGS" \
      CPPFLAGS="$DEP_CPPFLAGS" \
      LDFLAGS="$ARCH_LDFLAGS $DEP_LDFLAGS" \
      PKG_CONFIG_PATH="${DEP_PKGCONFIG#:}" \
      "$srcdir/configure" \
      --prefix="$PREFIX" $linkage $hostarg $flags $crossflags
  )
  make -C "$b" -j "$(njobs)"
  make -C "$b" install
}

recipe_openssl() { # recipe_openssl <name> <srcdir>
  local name=$1 srcdir=$2 target flags="" f
  case "$ARCH" in
    arm64) target=darwin64-arm64-cc ;;
    x86_64) target=darwin64-x86_64-cc ;;
    *) die "openssl: unsupported arch $ARCH" ;;
  esac
  # shared vs no-shared comes from configure_flags, like build.py
  while IFS= read -r f; do flags="$flags$(expand_tokens "$f") "; done \
    <<<"$(dep_get "$name" '(.configure_flags // [])[]')"
  (
    cd "$srcdir"
    env CC=clang CFLAGS="$ARCH_FLAGS" \
      ./Configure "$target" --prefix="$PREFIX" --libdir=lib $flags
  )
  make -C "$srcdir" -j "$(njobs)"
  make -C "$srcdir" install_sw
}

build_dep() { # build_dep <name>; fetch, extract and build into $PREFIX
  local name=$1 srcdir archive kind
  log "building $name for $ARCH"
  archive=$(fetch_source "$name" "$WORK/srcs")
  rm -rf "$WORK/build/$name"
  srcdir=$(extract "$archive" "$WORK/build/$name")
  kind=$(dep_get "$name" '.kind')
  case "$kind" in
    cmake) recipe_cmake "$name" "$srcdir" ;;
    configure) recipe_configure "$name" "$srcdir" ;;
    openssl) recipe_openssl "$name" "$srcdir" ;;
    *) die "$name: unknown kind '$kind'" ;;
  esac
}
