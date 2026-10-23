#!/usr/bin/env python3
"""Zen Delay Guildfordia's Mod — patcher.

Turns Erica Synths' official Zen Delay 1.1.0 update file into a modded update file, on your computer.
This repository contains no Erica Synths code: you provide the official file, the script decodes it,
checks it is exactly 1.1.0, applies the mod's own bytes (patch.json) and encodes a new update file.

Usage:
  python zen_patch.py ZenDelay_V1.1.0.wav zen_delay_guildfordia_mod.wav

Requires Python 3 + numpy. Then play the output file into the Zen like an official update (see README.md).
"""
import argparse
import hashlib
import json
import os
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "tools"))
import qpsk_decode  # noqa: E402
import qpsk_encode  # noqa: E402

PAUSE = 3.5   # seconds: longer flash-erase pauses than the official file (more reliable), see README


def decode(path):
    w = wave.open(path)
    if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, 48000):
        sys.exit(f"{path}: not the official update file (expected mono 16-bit 48 kHz)")
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float) / 32768
    symbols, _ = qpsk_decode.demodulate(x, 48000, 6000, 8)
    _, packets, bad = qpsk_decode.find_packets(symbols, 256)
    if len(packets) != 384 or bad:
        sys.exit(f"{path}: could not decode it cleanly ({len(packets)}/384 packets) - use the original download")
    return b"".join(packets)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("official_wav", help="ZenDelay_V1.1.0.wav downloaded from Erica Synths")
    ap.add_argument("out_wav", help="modded update file to write")
    a = ap.parse_args()

    patch = json.load(open(os.path.join(HERE, "patch.json")))
    fw = bytearray(decode(a.official_wav))
    if hashlib.sha256(fw).hexdigest() != patch["input_sha256"]:
        sys.exit("this is not the official Zen Delay 1.1.0 firmware - refusing to patch")
    for c in patch["changes"]:
        new = bytes.fromhex(c["bytes"])
        fw[c["offset"]:c["offset"] + len(new)] = new
    if hashlib.sha256(fw).hexdigest() != patch["output_sha256"]:
        sys.exit("internal error: patched image does not match the expected result")

    pcm = qpsk_encode.encode(bytes(fw), PAUSE)
    with wave.open(a.out_wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(pcm.tobytes())

    # self-check: the written file must decode back to the patched image
    if decode(a.out_wav) != bytes(fw):
        sys.exit("internal error: the written file does not decode back correctly")
    print(f"OK -> {a.out_wav} ({len(pcm) / 48000:.1f} s). Play it into the Zen's L IN in update mode (README).")


if __name__ == "__main__":
    main()
