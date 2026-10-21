# Third-party code

## libFLAC 1.5.0

- Location: `Packages/PointFlacKit/Sources/CFLAC/` (vendored source target `CFLAC`)
- Upstream: https://github.com/xiph/flac, release 1.5.0
- Tarball: `https://github.com/xiph/flac/releases/download/1.5.0/flac-1.5.0.tar.xz`
- SHA-256 of tarball: `f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920`
- Licence: Xiph BSD-3-Clause (`Packages/PointFlacKit/Sources/CFLAC/COPYING.Xiph`)
- Modifications: none to upstream files. Added by pointFlac: `config.h`, `include/CFLAC.h`, `include/module.modulemap`.
- Left out: `ogg_*.c` (no Ogg support), `windows_unicode_filenames.c`, the command-line tools, and every GPL or LGPL
  part of the tarball. That includes five headers from `include/share/` that an earlier copy carried by mistake,
  although no compiled source includes them:
  - `getopt.h` (GNU C Library, LGPL),
  - `grabbag.h`, `replaygain_analysis.h` and `replaygain_synthesis.h` (LGPL 2.1),
  - `utf8.h`, which has no notice of its own but belongs to upstream's GPL `src/share/utf8` module.

  The remaining `include/share/` headers (`alloc.h`, `compat.h`, `endswap.h`, `macros.h`, `private.h`, `safe_str.h`,
  `win_utf8_io.h`) carry the Xiph BSD licence. The encoder sources stay, BSD-licensed and unused (ledger T3).
- Guard: stage 1 of `scripts/test.sh` fails if any file under `CFLAC` carries a GPL or LGPL notice, and if
  `App/ThirdPartyNotices.txt` no longer reproduces `COPYING.Xiph` and `LICENSE` word for word.
- Notice: `App/ThirdPartyNotices.txt` (the libFLAC BSD-3 notice with the Xiph copyright, and pointFlac's MIT licence)
  ships in the app bundle in every configuration, Release included. The debug UI shows it under "Licences".
  `scripts/make-ipa.sh` fails if a Release app lacks it.
