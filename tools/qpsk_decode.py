#!/usr/bin/env python3
"""Decode a Zen Delay firmware .wav (Mutable Instruments stm-audio-bootloader QPSK format).

Encoder reference (MIT): pichenettes/stm-audio-bootloader, qpsk/encoder.py
  - 1 s silence intro, then a "blank" (symbol 0 = pure carrier)
  - packets: preamble [0]*8 + [0x99]*4 + [0xcc]*4, `packet_size` data bytes, CRC32 big-endian
  - 4 symbols per byte, MSB first; symbol bit0 -> sin (Q), bit1 -> cos (I)
  - carrier phase is tied to the absolute sample index, so no PLL is needed on a clean file.

Usage: qpsk_decode.py in.wav out.bin [--carrier 6000] [--symbol-samples N] [--packet-size 256]
"""
import argparse
import sys
import wave
import zlib

import numpy as np

PREAMBLE = bytes([0x99] * 4 + [0xCC] * 4)


def demodulate(x, sr, carrier, sps):
    n = np.arange(len(x))
    phase = 2 * np.pi * carrier * n / sr
    q = x * np.sin(phase)
    i = x * np.cos(phase)
    m = len(x) // sps * sps
    q = q[:m].reshape(-1, sps).sum(1)
    i = i[:m].reshape(-1, sps).sum(1)
    energy = np.abs(x[:m]).reshape(-1, sps).mean(1)
    symbols = (q > 0).astype(np.uint8) | ((i > 0).astype(np.uint8) << 1)
    return symbols, energy


def symbols_to_bytes(symbols):
    m = len(symbols) // 4 * 4
    s = symbols[:m].reshape(-1, 4)
    return bytes((s[:, 0] << 6 | s[:, 1] << 4 | s[:, 2] << 2 | s[:, 3]).tolist())


def find_packets(symbols, packet_size):
    # Try the 4 possible byte alignments; keep the one yielding the most CRC-valid packets.
    best = None
    for offset in range(4):
        stream = symbols_to_bytes(symbols[offset:])
        packets, bad, pos = [], 0, 0
        while True:
            pos = stream.find(PREAMBLE, pos)
            if pos < 0:
                break
            start = pos + len(PREAMBLE)
            # skip extra 0xcc if the sync matched early
            body = stream[start:start + packet_size + 4]
            if len(body) < packet_size + 4:
                break
            data, crc = body[:packet_size], int.from_bytes(body[packet_size:], "big")
            if zlib.crc32(data) & 0xFFFFFFFF == crc:
                packets.append(data)
                pos = start + packet_size + 4
            else:
                bad += 1
                pos += 1
        if best is None or len(packets) > len(best[1]):
            best = (offset, packets, bad)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("out")
    ap.add_argument("--carrier", type=float, default=6000)
    ap.add_argument("--symbol-samples", type=int, default=0, help="0 = try 6, 8, 12, 16, 24")
    ap.add_argument("--packet-size", type=int, default=256)
    a = ap.parse_args()

    w = wave.open(a.wav)
    sr = w.getframerate()
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float) / 32768
    if w.getnchannels() > 1:
        x = x.reshape(-1, w.getnchannels())[:, 0]

    candidates = [a.symbol_samples] if a.symbol_samples else [6, 8, 12, 16, 24]
    results = []
    for sps in candidates:
        symbols, _ = demodulate(x, sr, a.carrier, sps)
        offset, packets, bad = find_packets(symbols, a.packet_size)
        print(f"samples/symbol={sps}: {len(packets)} valid packets, {bad} bad CRC (byte offset {offset})")
        results.append((len(packets), sps, packets))
    count, sps, packets = max(results)
    if not count:
        sys.exit("no valid packet found")
    data = b"".join(packets)
    with open(a.out, "wb") as f:
        f.write(data)
    print(f"-> {a.out}: {len(data)} bytes from {count} packets (samples/symbol={sps})")


if __name__ == "__main__":
    main()
