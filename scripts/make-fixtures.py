#!/usr/bin/env python3
"""Generate the deterministic FLAC fixture set for PFTestSupport.

Standard library only; needs `ffmpeg` and `lame` on PATH. Idempotent: output is byte-identical per run.
Output: Packages/PointFlacKit/Sources/PFTestSupport/Resources/Fixtures/
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Packages/PointFlacKit/Sources/PFTestSupport/Resources/Fixtures")
FRAMES = 4096
SEED = 0x5EED


# ---------- signal ----------
def signal(frames, bits, channels):
    """Interleaved native-range samples. Channel 1 (when channels == 2) is the bit walk;
    every other channel c is LCG noise with seed 0x5EED + c. Mono is the left channel only."""
    chans = []
    for c in range(channels):
        if channels == 2 and c == 1:
            col = []
            for n in range(frames):
                v = 1 << (n % (bits - 1))
                col.append(-v if n % 2 == 1 else v)
        else:
            x = (SEED + c) & 0xFFFFFFFF
            col = []
            for _ in range(frames):
                x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
                s = x - (1 << 32) if x & 0x80000000 else x
                col.append(s >> (32 - bits))
        chans.append(col)
    return [chans[c][n] for n in range(frames) for c in range(channels)]


def pack(samples, fmt="<i"):
    return struct.pack("<%di" % len(samples), *samples)


# ---------- FLAC parsing ----------
def crc8(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def metadata_blocks(buf):
    """Returns ([(type, body_offset, body_len)], first_frame_offset)."""
    assert buf[:4] == b"fLaC"
    pos, blocks = 4, []
    while True:
        h = buf[pos]
        last, typ = h & 0x80, h & 0x7F
        length = int.from_bytes(buf[pos + 1 : pos + 4], "big")
        blocks.append((typ, pos + 4, length))
        pos += 4 + length
        if last:
            return blocks, pos


def frame_header_len(buf, pos):
    """Length of the frame header at pos including its CRC-8 byte, or None if not a valid header."""
    if pos + 6 > len(buf) or buf[pos] != 0xFF or buf[pos + 1] & 0xFE != 0xF8:
        return None
    bs_code, sr_code = buf[pos + 2] >> 4, buf[pos + 2] & 0xF
    i = pos + 4
    lead = buf[i]
    i += 1
    if lead & 0x80:
        n = 0
        while lead & (0x80 >> (n + 1)):
            n += 1
        i += n
    if bs_code == 6:
        i += 1
    elif bs_code == 7:
        i += 2
    if sr_code == 12:
        i += 1
    elif sr_code in (13, 14):
        i += 2
    if i >= len(buf) or crc8(buf[pos:i]) != buf[i]:
        return None
    return i + 1 - pos


def find_frames(buf, start):
    """Frame start offsets, validated by header CRC-8 and the preceding frame's CRC-16."""
    assert frame_header_len(buf, start)
    starts = [start]
    pos = start + 1
    while pos < len(buf):
        if frame_header_len(buf, pos) and crc16(buf[starts[-1] : pos - 2]) == int.from_bytes(buf[pos - 2 : pos], "big"):
            starts.append(pos)
        pos += 1
    assert crc16(buf[starts[-1] : -2]) == int.from_bytes(buf[-2:], "big")
    return starts


# ---------- encoding ----------
def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def encode(tmp, name, rate, bits, ch, samples, block=None):
    src = os.path.join(tmp, name + ".pcm")
    dst = os.path.join(tmp, name + ".flac")
    if bits == 16:
        data, fmt = struct.pack("<%dh" % len(samples), *samples), "s16le"
    else:
        data, fmt = pack([s << (32 - bits) for s in samples]), "s32le"
    with open(src, "wb") as f:
        f.write(data)
    cmd = ["ffmpeg", "-v", "error", "-y", "-fflags", "+bitexact", "-flags:a", "+bitexact",
           "-f", fmt, "-ar", str(rate), "-ac", str(ch)]
    if ch == 6:
        cmd += ["-channel_layout", "5.1(side)"]
    cmd += ["-i", src, "-map_metadata", "-1", "-c:a", "flac"]
    if bits == 16:
        cmd += ["-sample_fmt", "s16"]
    else:
        cmd += ["-sample_fmt", "s32", "-bits_per_raw_sample", str(bits)]
    if bits == 32:
        cmd += ["-strict", "experimental"]
    if block:
        cmd += ["-frame_size", str(block)]
    cmd += [dst]
    run(cmd)
    with open(dst, "rb") as f:
        return bytearray(f.read())


def make_mp3(tmp):
    pcm = os.path.join(tmp, "mp3.pcm")
    mp3 = os.path.join(tmp, "x.mp3")
    with open(pcm, "wb") as f:
        s = signal(44100, 16, 2)
        f.write(struct.pack("<%dh" % len(s), *s))
    run(["lame", "--quiet", "--nohist", "-r", "-s", "44.1", "--bitwidth", "16", "--little-endian", "-m", "j",
         "-b", "64", pcm, mp3])
    with open(mp3, "rb") as f:
        return f.read()


def id3v24_tag():
    body_len = 64 - 10
    header = b"ID3" + bytes([4, 0, 0]) + bytes((body_len >> s) & 0x7F for s in (21, 14, 7, 0))
    frame_body = b"\x03" + b"pointFlac fixture\x00"  # UTF-8 text encoding
    frame = b"TIT2" + bytes((len(frame_body) >> s) & 0x7F for s in (21, 14, 7, 0)) + b"\x00\x00" + frame_body
    tag = header + frame
    tag += b"\x00" * (64 - len(tag))
    assert len(tag) == 64
    return bytes(tag)


# ---------- main ----------
def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    manifest = []
    tmp = tempfile.mkdtemp()
    try:
        def add(name, rate, bits, ch, flac_bytes, samples, frames=FRAMES, expect="accept", rejection=None,
                has_md5=True, multichannel=False, ext="flac"):
            fname = "%s.%s" % (name, ext)
            with open(os.path.join(OUT, fname), "wb") as f:
                f.write(flac_bytes)
            raw = None
            if samples is not None:
                raw = name + ".raw"
                with open(os.path.join(OUT, raw), "wb") as f:
                    f.write(pack(samples))
            manifest.append({"name": name, "file": fname, "raw": raw, "sampleRate": rate, "bits": bits,
                             "channels": ch, "frames": frames, "expect": expect, "rejection": rejection,
                             "hasMD5": has_md5, "multichannel": multichannel})

        def plain(name, rate, bits, ch, **kw):
            s = signal(FRAMES, bits, ch)
            data = encode(tmp, name, rate, bits, ch, s)
            add(name, rate, bits, ch, bytes(data), s, **kw)
            return data, s

        base, _ = plain("s16-44100", 44100, 16, 2)
        plain("s16-48000", 48000, 16, 2)
        plain("s16-44100-mono", 44100, 16, 1)
        for r in (44100, 48000, 88200, 96000, 176400, 192000, 384000):
            plain("s24-%d" % r, r, 24, 2)
        for r in (44100, 48000, 96000, 192000):
            plain("s32-%d" % r, r, 32, 2)
        plain("s16-48000-6ch", 48000, 16, 6, multichannel=True)

        # id3-s24-48000
        s = signal(FRAMES, 24, 2)
        data = encode(tmp, "id3src", 48000, 24, 2, s)
        add("id3-s24-48000", 48000, 24, 2, id3v24_tag() + bytes(data), s)

        # nomd5-s16-44100
        s = signal(FRAMES, 16, 2)
        data = encode(tmp, "nomd5src", 44100, 16, 2, s)
        blocks, _ = metadata_blocks(data)
        typ, off, ln = blocks[0]
        assert typ == 0 and ln == 34
        data[off + 18 : off + 34] = b"\x00" * 16
        add("nomd5-s16-44100", 44100, 16, 2, bytes(data), s, has_md5=False)

        # corrupt-mid-s16-44100
        s = signal(16384, 16, 2)
        data = encode(tmp, "corruptsrc", 44100, 16, 2, s, block=4096)
        _, first = metadata_blocks(data)
        starts = find_frames(data, first)
        assert len(starts) == 4, starts
        third_start, fourth_start = starts[2], starts[3]
        hdr = frame_header_len(data, third_start)
        payload_lo, payload_hi = third_start + hdr, fourth_start - 2
        data[(payload_lo + payload_hi) // 2] ^= 0xFF
        add("corrupt-mid-s16-44100", 44100, 16, 2, bytes(data), s, frames=16384)

        # renamed-mp3
        add("renamed-mp3", 0, 0, 0, make_mp3(tmp), None, frames=0, expect="reject", rejection="badMagic")

        # truncated-meta
        _, first = metadata_blocks(base)
        add("truncated-meta", 44100, 16, 2, bytes(base[:first]), None, expect="reject", rejection="truncated")

        # bad-streaminfo
        data = bytearray(base)
        blocks, _ = metadata_blocks(data)
        _, off, _ = blocks[0]
        data[off : off + 2] = b"\x00\x00"
        add("bad-streaminfo", 44100, 16, 2, bytes(data), None, expect="reject", rejection="invalidStreamInfo")

        # bad-frame-crc
        data = bytearray(base)
        _, first = metadata_blocks(data)
        data[first + frame_header_len(data, first) - 1] ^= 0x01
        add("bad-frame-crc", 44100, 16, 2, bytes(data), None, expect="reject", rejection="frameCRCMismatch")

        # empty
        add("empty", 0, 0, 0, b"", None, frames=0, expect="reject", rejection="truncated")

        # not-flac-name
        add("not-flac-name", 44100, 16, 2, bytes(base), None, expect="reject", rejection="notFlacName", ext="wav")

        assert len(manifest) == 24, len(manifest)
        with open(os.path.join(OUT, "manifest.json"), "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.write("\n")
    finally:
        shutil.rmtree(tmp)
    print("wrote %d fixtures to %s" % (len(manifest), OUT))


if __name__ == "__main__":
    sys.exit(main())
