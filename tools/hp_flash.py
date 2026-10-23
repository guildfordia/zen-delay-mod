#!/usr/bin/env python3
"""Play an update .wav into the Zen from a Mac's headphone output (Erica's official update method).

Plays the file on both channels of the "External Headphones" device at 48 kHz (CoreAudio sample-rate
conversion forbidden, so the signal stays bit-exact), sets the system volume to 100 %, file at --gain-db
(default -3 dB). Cable: headphone out -> Zen L IN, nothing in R IN, IN LEVEL at 12 o'clock.
Flashing through a mixer / audio interface also works but was less reliable in our tests.
On other systems, any player that outputs the file unaltered at 48 kHz (e.g. VLC) works too.

Usage (macOS): python tools/hp_flash.py WAV [--gain-db -3]
"""
import argparse
import subprocess
import wave

import numpy as np
import sounddevice as sd

SR = 48000
DEVICE = "External Headphones"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("--gain-db", type=float, default=-3.0)
    a = ap.parse_args()

    w = wave.open(a.wav)
    if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, SR):
        raise SystemExit(f"{a.wav}: expected mono 16-bit {SR} Hz")
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16) / 32768 * 10 ** (a.gain_db / 20)
    y = np.stack([x, x], 1).astype(np.float32)
    dev = [i for i, d in enumerate(sd.query_devices()) if d["name"] == DEVICE]
    if not dev:
        raise SystemExit(f"no '{DEVICE}' device: is the cable plugged into the Mac headphone jack?")
    subprocess.run(["osascript", "-e", "set volume output volume 100 without output muted"], check=True)
    cs = sd.CoreAudioSettings(change_device_parameters=True, fail_if_conversion_required=True)
    print(f"{len(x) / SR:.1f} s on {DEVICE} (L+R), {a.gain_db:+.1f} dB, system volume 100 %", flush=True)
    sd.play(y, SR, device=dev[0], extra_settings=cs, latency="high", blocking=True)
    print("stream status:", sd.get_status() or "clean")


if __name__ == "__main__":
    main()
