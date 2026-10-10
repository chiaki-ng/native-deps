# native-deps

Builds the native dependencies that chiaki-ng projects (Chiaki-ng for macOS,
Akira) need, from the exact upstream sources each project pins. One manifest —
`deps.toml` — drives everything: which libraries, which versions, which source
URL, which SHA-256, and with which flags. GitHub Actions builds them from
source and publishes two rolling releases:

- [`sources`](https://github.com/chiaki-ng/native-deps/releases/tag/sources) — the pinned, SHA-verified upstream archives (this repo constructs that release; the upstream URL is the only input)
- [`builds`](https://github.com/chiaki-ng/native-deps/releases/tag/builds) — prebuilt prefix tarballs plus `SHA256SUMS` and `build.json` (resolved versions, toolchain, hashes)

## The manifest

`deps.toml` has one `[[<platform>]]` table per library per platform, plus a
`[config.<platform>]` section:

```toml
[config.darwin]
deployment_target = "26.0"
architectures = ["arm64"]

[[darwin]]
name = "openssl"
version = "3.6.4"
url = "https://github.com/openssl/openssl/releases/download/openssl-{version}/openssl-{version}.tar.gz"
sha256 = "9bff…"
kind = "openssl"                # cmake | configure | openssl
depends_on = []                 # names of other entries built first
configure_flags = ["no-tests"]
```

- `url` supports `{version}`, `{version_us}` (dots→underscores) and `{name}` placeholders.
- `kind` picks the build recipe: `cmake` (with a `cmake_options` table), `configure` (autotools; `cross_configure_flags` apply when cross-compiling), or `openssl` (its own `Configure`).
- Flags may use `@ARCH@` (target arch) and `@POOL@` (directory holding the built deps) tokens.
- A different platform with different pins is just another array (`[[switch]]`, …) — no override semantics.

Everything is built statically (`BUILD_SHARED_LIBS=OFF` / `--disable-shared`),
so tarballs contain plain `prefix/{include,lib,bin}` trees to link into an app
bundle.

## Bumping a version (the PR flow)

```sh
pip3 install tomlkit              # only needed for bumping
scripts/bump.sh openssl 3.6.5     # downloads upstream, verifies/computes sha256, rewrites deps.toml
git checkout -b bump-openssl-3.6.5 && git add deps.toml
git commit -m "openssl 3.6.5" && gh pr create
```

`bump.sh` rewrites the pin through tomlkit, so comments and layout survive.
The PR triggers `verify.yml`, which validates the manifest and builds the
matrix; unchanged deps come from cache (their cache key hashes the dep's
entry, its transitive dependencies' entries, the platform config and the
build scripts), so only what actually changed compiles. Merging to `main`
publishes fresh `builds` and `sources` assets.

## CI pipeline

`build-darwin.yml`, derived entirely from `deps.toml` (no dep lists live in
the workflows):

1. **plan** — validates the manifest, emits the `dep × arch` matrix and per-dep content-hash cache keys.
2. **build** — one job per dep/arch on the `macos-26` (arm64) image. `arm64` builds natively; if `x86_64` is ever added to `architectures` it is cross-compiled on the same image (including a host `protoc` for protobuf). Per-dep results are cached and uploaded as artifacts.
3. **assemble** — merges the per-dep pools into one prefix per arch, packages `native-deps-<rev>-darwin-<arch>.tar.zst` with `build-<arch>.json`.
4. **publish** (push to main, or dispatch with `publish`) — lipo-merges a universal slice when both arches are built, writes `SHA256SUMS` + `build.json`, uploads to the `builds` release, then re-downloads every pinned archive from upstream, re-verifies the SHA-256s and (re)builds the `sources` release.

Binaries are compiled with the runner's Xcode against
`MACOSX_DEPLOYMENT_TARGET` from `[config.darwin]` (26.0), so they run on
macOS 26 and newer.

## Consuming

Download from the `builds` release, verify against `SHA256SUMS`, and point
your build at `prefix/` (`CMAKE_PREFIX_PATH`, `PKG_CONFIG_PATH`, …). Pin the
tarball's SHA-256 in the consuming project, the same way source archives are
pinned — the release is a distribution channel, not a trust anchor.

## Building locally

Same scripts CI uses, on an arm64 Mac with Xcode, `jq`, `zstd` and python 3.11+:

```sh
make build ARCH=arm64      # out/arm64/pool/<name>/…  (re-runnable; skips built deps)
make package ARCH=arm64    # dist/native-deps-…-darwin-arm64.tar.zst
make lint                  # validate deps.toml
```

## Notes and caveats

- The `macos-26` runner label is set in `env.RUNNER_IMAGE` in `build-darwin.yml` and `plan.sh`'s default; swap both to `macos-15` if the label isn't available.
- ffmpeg's flags are a seed for a remote-play client (VideoToolbox H.264/HEVC, AudioToolbox, the decoders chiaki-ng consumes). Keep them aligned with chiaki-ng's in-repo ffmpeg build script.
- protobuf cross builds compile a host `protoc` first; its cmake fetches `utf8_range` over the network.
- If two platforms ever pin the same library version but different SHA-256s, the shared `sources` release filename scheme collides — prefix filenames per platform if that day comes.
