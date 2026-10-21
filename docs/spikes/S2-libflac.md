# Spike S2: libFLAC as a vendored source target

**Result: PASS.**

## Approach

libFLAC 1.5.0 is vendored as source, as the C target `CFLAC` in `Packages/PointFlacKit`. It is not a prebuilt binary XCFramework.
Reasons: auditable and reproducible from a pinned tarball (SHA-256 in `docs/third-party.md`), one build for iOS, simulator and macOS test host, no binary blob in the repo, and Apple's own decoder cannot do 32-bit FLAC.
Upstream files are byte-identical; the only added files are `config.h`, `include/CFLAC.h` and `include/module.modulemap`.

## Layout

- `libFLAC/*.c`, `libFLAC/include/{private,protected}`, `libFLAC/deduplication/*.c` (fragments #included by other sources; excluded from compilation in `Package.swift`)
- `include/FLAC/*.h`, `include/share/*.h`, `include/CFLAC.h` (umbrella for `import CFLAC`)
- `include/module.modulemap`: needed because SwiftPM rejects an umbrella header that has sibling directories (`FLAC/`, `share/`)

## Config choices (`config.h`, from `config.cmake.h.in`)

Little-endian, 64-bit words, no Ogg (`FLAC__HAS_OGG 0`), no x86 or NEON intrinsics (the `*_intrin_*.c` files compile to nothing), `HAVE_STDINT_H`, `HAVE_INTTYPES_H`, `HAVE_FSEEKO`, `HAVE_LROUND`, `HAVE_SYS_PARAM_H`, `FLAC__SYS_DARWIN`, `PACKAGE_VERSION "1.5.0"`.
Compile flags: `HAVE_CONFIG_H`, header search paths `.`, `include`, `libFLAC/include`, and `-w` (via `unsafeFlags`, allowed because the package is local) to keep vendor warnings out of the build output.

## Build times observed (this Mac, cold-ish)

- `swift test --filter CFLACSmokeTests`: about 16 s including the CFLAC compile
- `xcodebuild build-for-testing`, device (`generic/platform=iOS`): about 23 s
- `xcodebuild build-for-testing`, simulator (`generic/platform=iOS Simulator`, arm64 + x86_64): about 26 s

The package scheme is `PointFlacKit` and only builds CFLAC through the test targets, so `build-for-testing` was used to force CFLAC to compile for iOS.

## Fallback

If the source target ever causes trouble, switch to sbooth's `flac-binary-xcframework` (prebuilt libFLAC XCFramework), keeping the `CFLAC` module name.
