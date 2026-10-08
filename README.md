# native-deps

Mirror of the upstream source archives that Chiaki-ng for macOS builds its native dependencies from.

The archives live on the [`sources` release](https://github.com/chiaki-ng/native-deps/releases/tag/sources). They are unmodified copies of the upstream releases, kept so that older versions of the app stay buildable if an upstream download disappears.

The Chiaki-ng build downloads from this mirror first and falls back to the upstream URL. Every archive is checked against the SHA-256 pinned in the app's repository, so the mirror is a convenience, not a trust anchor.

Each archive keeps its own upstream licence; see the licence files inside it.
