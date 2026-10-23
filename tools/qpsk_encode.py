#!/usr/bin/env python3
"""Encode a firmware .bin into a Zen Delay update .wav (stm-audio-bootloader QPSK, inverse of qpsk_decode.py).

Same modulation as the official file: 48 kHz mono 16-bit, carrier 6000 Hz, 8 samples/symbol, 256-byte packets
(preamble [0]*8 + [0x99]*4 + [0xcc]*4, data, CRC32 big-endian), 4 symbols per byte MSB first,
symbol bit0 -> sin (Q), bit1 -> cos (I), each at 1/sqrt(2).

Timing copied from ZenDelay_V1.1.0.wav, because the bootloader needs
silence while it erases/writes flash:
  1 s silence, 1 s carrier blank, then 16 KB blocks (64 packets) back to back, followed by a blank of
  2.5 s after blocks 1-3, 0.2 s after blocks 4-5, and a 5.2 s blank after the last one.

Usage: qpsk_encode.py in.bin out.wav [--min-pause S]

2026-10-23: home flashes fail ~20-30 s in (around a pause). --min-pause 5 gives the bootloader more time
to erase/write between blocks; the extra pauses are plain carrier, like the official ones.
"""
import argparse
import sys
import wave
import zlib

import numpy as np

SR = 48000
CARRIER = 6000
SPS = 8                       # samples per symbol -> 2 bits / 8 samples = 12 kbit/s
BIT_RATE = SR // SPS * 2
PACKET = 256
BLOCK = 16384
PREAMBLE = bytes([0] * 8 + [0x99] * 4 + [0xCC] * 4)
PAUSE_AFTER_BLOCK = [2.5, 2.5, 2.5, 0.2, 0.2]   # seconds, blocks 1..5 (official 96 KB image)
OUTRO = 5.2


def blank_symbols(seconds):
    # same rounding as the reference encoder: whole bytes of symbol 0 (pure carrier)
    return [0] * (int(seconds * BIT_RATE / 8) * 4)


def byte_symbols(data):
    return [(b >> s) & 3 for b in data for s in (6, 4, 2, 0)]


def packet_symbols(data):
    data = data.ljust(PACKET, b"\x00")
    crc = zlib.crc32(data) & 0xFFFFFFFF
    return byte_symbols(PREAMBLE + data + crc.to_bytes(4, "big"))


def modulate(symbols):
    s = np.repeat(np.array(symbols, dtype=np.int64), SPS)
    q = (2 * (s & 1) - 1) / np.sqrt(2)
    i = (2 * (s >> 1) - 1) / np.sqrt(2)
    phase = 2 * np.pi * CARRIER * (np.arange(len(s)) / SR)
    return q * np.sin(phase) + i * np.cos(phase)


def encode(fw, min_pause=0.0):
    if len(fw) % BLOCK:
        fw += b"\xff" * (BLOCK - len(fw) % BLOCK)
    blocks = [fw[k:k + BLOCK] for k in range(0, len(fw), BLOCK)]
    if len(blocks) - 1 > len(PAUSE_AFTER_BLOCK):
        sys.exit(f"{len(blocks)} blocks: no measured pause timing beyond {len(PAUSE_AFTER_BLOCK) + 1}")
    symbols = blank_symbols(1.0)
    for n, block in enumerate(blocks):
        for k in range(0, BLOCK, PACKET):
            symbols += packet_symbols(block[k:k + PACKET])
        # only the erase pauses (>= 1 s in the official file) are lengthened: a long silence where the official file has
        # 0.2 s is taken by the bootloader as the END of the update (2026-10-23: it stopped after block 5 and booted)
        p = PAUSE_AFTER_BLOCK[n] if n < len(blocks) - 1 else OUTRO
        symbols += blank_symbols(max(p, min_pause) if n < len(blocks) - 1 and p >= 1.0 else p)
    signal = np.concatenate([np.zeros(SR), modulate(symbols)])
    return (signal * 32767).astype(np.int16)  # truncation, like the official file


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bin")
    ap.add_argument("wav")
    ap.add_argument("--min-pause", type=float, default=0.0,
                    help="lengthen the erase pauses (after blocks 1-3; the 0.2 s ones are kept) to at least this many seconds (more time for flash erase/write)")
    a = ap.parse_args()

    pcm = encode(open(a.bin, "rb").read(), a.min_pause)
    with wave.open(a.wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"-> {a.wav}: {len(pcm)} samples, {len(pcm) / SR:.3f} s")


if __name__ == "__main__":
    main()
