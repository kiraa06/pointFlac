/* config.h for libFLAC 1.5.0 as vendored in pointFlac (Apple arm64 / x86_64).
   Derived from upstream config.cmake.h.in. Decoder-focused: no Ogg, no SIMD intrinsics. */
#ifndef CFLAC_CONFIG_H
#define CFLAC_CONFIG_H

#define CPU_IS_LITTLE_ENDIAN 1
#define CPU_IS_BIG_ENDIAN 0
#define WORDS_BIGENDIAN CPU_IS_BIG_ENDIAN
#define ENABLE_64_BIT_WORDS 1

#define OGG_FOUND 0
#define FLAC__HAS_OGG OGG_FOUND

#define FLAC__HAS_X86INTRIN 0
#define FLAC__HAS_NEONINTRIN 0
#define FLAC__HAS_A64NEONINTRIN 0

#define FLAC__SYS_DARWIN 1

#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_FSEEKO 1
#define HAVE_LROUND 1
#define HAVE_SYS_PARAM_H 1

#define PACKAGE_VERSION "1.5.0"

#ifndef _DARWIN_USE_64_BIT_INODE
#define _DARWIN_USE_64_BIT_INODE 1
#endif
#ifndef _FILE_OFFSET_BITS
#define _FILE_OFFSET_BITS 64
#endif
#ifndef _LARGEFILE_SOURCE
#define _LARGEFILE_SOURCE
#endif

#endif
