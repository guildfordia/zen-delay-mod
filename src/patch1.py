#!/usr/bin/env python3
"""Patch 1 (tap x multiplier + mode gestures) — byte patches on the decoded 1.1.0 image.

Behaviour: see README.md. Builds the patched image from the decoded official 1.1.0 image (needs arm-none-eabi binutils).
Each patch checks the original bytes before writing, so it refuses to run on the wrong image.
Hooks (new code) are written in *.S (clock_hook.S, hold_hook.S), placed by patch1.ld, built with arm-none-eabi-as/ld.

Usage: patch1.py [in.bin] [out.bin]
  defaults: firmware/decoded/zen_1.1.0.bin -> firmware/patched/zen_1.1.0_patch1.bin
"""
import hashlib
import subprocess
import sys
from pathlib import Path

BASE = 0x08008000
ORIG_SHA256 = "22ad0e738b7e113311d102c4c340c237575cd166847b98b806bf876aa1f282f7"

# RAM zeroed at boot for our hooks: 0x2000bb3c..0x2000bb5f (hold stage, MIDI reader state, CC values/flags).
# It was a 4-byte alignment gap before the heap; the heap now starts 32 bytes later (8 KB -> 8160 bytes).
OUR_RAM = (0x2000BB3C, 0x2000BB60)

# (address, original bytes, new bytes, why)
PATCHES = [
    (0x08016984, bytes.fromhex("a4070000"), bytes.fromhex("c8070000"),
     "scatter-load zero-init size 0x7a4 -> 0x7c8: our RAM 0x2000bb3c..0x2000bb5f is zeroed at every boot"),
    (0x080164E8, bytes.fromhex("47bb0020"), bytes.fromhex("67bb0020"),
     "heap base (0x2000bb47 & ~7 = 0x2000bb40) -> 0x2000bb60, out of our RAM"),
    # Control routine FUN_0800b398, delay-time dispatch on mode byte [base+0x78d].
    # Was: mode 1 (tap) -> own branch (exits tap if the knob moves), 2 -> division table, else free.
    # Now: mode 0 -> free, mode 1 or 2 -> division table (both use the beat period at [base+0x77c]).
    # The old tap branch 0x0800b55e..0x0800b5cf becomes dead code (free room for trampolines).
    (0x0800B556, bytes.fromhex("0129"), bytes.fromhex("0029"),
     "cmp r1,#1 -> cmp r1,#0"),
    (0x0800B558, bytes.fromhex("3ad1"), bytes.fromhex("3dd1"),
     "bne 0x0800b5d0 -> bne 0x0800b5d6 (tap/sync -> division table)"),
    (0x0800B55A, bytes.fromhex("b0f5803f"), bytes.fromhex("1ae100bf"),
     "cmp.w r0,#0x10000 -> b 0x0800b792 (free time) + nop"),
    # TAP LED tempo blink at the start of FUN_0800b878: originally only in sync mode, at the delay time.
    # Now in tap and sync mode, at the beat (tempo) whatever the division.
    (0x0800B884, bytes.fromhex("0228"), bytes.fromhex("0028"),
     "cmp r0,#2 -> cmp r0,#0 (TAP LED blink: mode test)"),
    (0x0800B888, bytes.fromhex("2dd1"), bytes.fromhex("2dd0"),
     "bne 0x0800b8e6 -> beq 0x0800b8e6 (blink unless free mode)"),
    (0x0800B8B8, bytes.fromhex("d5f87427"), bytes.fromhex("d5f87c27"),
     "ldr.w r2,[r5,#0x774] -> [r5,#0x77c] (blink period = tempo, not delay)"),
    # Tap function FUN_0800b9a8: a tap in SYNC used to only change the tempo; now it goes to TAP like
    # from FREE (pickup reset + mode = 1).
    (0x0800BA26, bytes.fromhex("09d1"), bytes.fromhex("00bf"),
     "bne 0x0800ba3c -> nop (tap in SYNC also switches to TAP)"),
    # Pot filter wake-up threshold of slots 9 (FEEDBACK) and 10 (DELAY TIME), literal loaded by main() at
    # 0x0800834e and stored in both descriptors (+0x20). 0.7 ADC count: noise/drift woke the knob up and
    # overwrote CC 20/23 values. 8 counts ~ 0.5 deg of rotation (user, 2026-10-23).
    (0x0800851C, bytes.fromhex("3333333f"), bytes.fromhex("00000041"),
     "pot wake threshold slots 9/10: 0.7 -> 8.0 ADC counts"),
    # Debug printf (FUN_080109d0 -> FUN_080135d4 -> FUN_08013800) only prints to a serial port nobody reads
    # ("New tapped tempo", "MCU load", asserts). Its single call to the formatter becomes a nop, which frees
    # 0x080135d4..0x08013a63 (no other absolute, relative or branch reference, checked 2026-10-23).
    (0x080109E8, bytes.fromhex("02f0f4fd"), bytes.fromhex("aff30080"),
     "bl 0x080135d4 (printf formatter) -> nop.w: debug prints off, frees ~1 KB"),
]

SOURCES = ["clock_hook.S", "hold_hook.S", "cc_hook.S", "led_hook.S", "send_hook.S", "dbl_hook.S", "div_hook.S"]
# Assembled hooks: (section, original bytes at its address, or the address range it may overwrite)
HOOKS = [
    (".site", bytes.fromhex("d4f8a80d")),         # 0x0800bb76 ldr.w r0,[r4,#0xda8] -> b.w clock_hook
    (".hook", (0x0800B55E, 0x0800B5D0)),          # old tap branch of FUN_0800b398, dead since patch 1
    (".hold_site", bytes.fromhex("95f8090d")),    # 0x0800b8e6 ldrb.w r0,[r5,#0xd09] -> b.w hold
    (".hold", (0x0801FDC4, 0x08020000)),          # free flash at the end of the image (573 x 0xFF)
    (".midi_site", bytes.fromhex("30b5dff8")),    # 0x0800bb3c push {r4,r5,lr} + half of ldr.w r4 -> b.w midi_rx
    (".potf_site", bytes.fromhex("01f0ccf9")),    # 0x0800b4d0 bl pot_filter -> bl cc_apply
    (".cc", (0x0801FE60, 0x08020000)),            # free flash, after .hold
    (".algo", (0x0801FE60, 0x08020000)),          # free flash, right after .cc
    (".tap", (0x0800B57A, 0x0800B5D0)),           # dead old tap branch, after .hook (clock_hook ends at 0x0800b57a)
    (".led_site", bytes.fromhex("d5f8a00d")),     # 0x0800b8b4 ldr.w r0,[r5,#0xda0] -> b.w led (TAP LED per mode)
    (".led", (0x0800B8EA, 0x0800B948)),           # stock long-press block after .hold_site, dead since hold_hook
    (".send_site", bytes.fromhex("98f88c07")),    # 0x08008f5c ldrb.w r0,[r8,#0x78c] -> b.w send_hook (CC 21 INPUT SEND)
    (".send", (0x080135D4, 0x08013700)),          # debug printf body (FUN_080135d4 + FUN_08013800), freed below
    (".dbl_site", bytes.fromhex("40f6b830")),     # 0x0800ba0c movw r0,#0xbb8 -> b.w dbl_tap (double TAP = freeze)
    (".dbl", (0x08013700, 0x08013730)),           # freed printf body, after .send
    (".frzled", (0x08013730, 0x08013770)),        # freeze LED cue, freed printf body after .dbl
    (".div_site", bytes.fromhex("81b2b1f5")),     # 0x0800b5d6 uxth r1,r0 + half cmp.w -> b.w div_zones (x0.75)
    (".divz", (0x08013770, 0x08013A64)),          # division table, freed printf body after .frzled
    (".fbk_site", bytes.fromhex("c8f8580c")),     # 0x0800b4f6 str.w r0,[r8,#0xc58] -> b.w fbk_hook (freeze = 1.0)
    (".fbk", (0x08013830, 0x08013A64)),           # freeze-safe feedback store, freed printf body after .divz
]


def build_hooks(here, out):
    out.mkdir(parents=True, exist_ok=True)
    objs, elf = [], out / "patch1.elf"
    for src in SOURCES:
        objs.append(out / src.replace(".S", ".o"))
        subprocess.run(["arm-none-eabi-as", "-mcpu=cortex-m4", "-mthumb", here / src, "-o", objs[-1]], check=True)
    subprocess.run(["arm-none-eabi-ld", "--fatal-warnings", "-T", here / "patch1.ld", *objs, "-o", elf], check=True)
    # section VMAs from the linked ELF
    hdr = subprocess.run(["arm-none-eabi-objdump", "-h", elf], check=True, capture_output=True, text=True).stdout
    vma = {f[1]: int(f[3], 16) for f in (l.split() for l in hdr.splitlines()) if len(f) > 3 and f[0].isdigit()}
    patches = []
    for sec, old in HOOKS:
        raw = out / f"{sec[1:]}.bin"
        subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", "-j", sec, elf, raw], check=True)
        code = raw.read_bytes()
        addr = vma[sec]
        if isinstance(old, tuple):
            lo, hi = old
            if not (lo <= addr and addr + len(code) <= hi):
                sys.exit(f"{sec}: 0x{addr:08x}+{len(code)} does not fit in {lo:#x}..{hi:#x}")
            old = None
        elif len(old) != len(code):
            sys.exit(f"{sec}: {len(code)} bytes, expected {len(old)}")
        patches.append((addr, old, code, f"{sec} ({len(code)} bytes)"))
    return patches


def apply(img, patches):
    for addr, old, new, why in patches:
        off = addr - BASE
        if old is None:  # dead code: whatever is there gets replaced
            old = bytes(img[off:off + len(new)])
        if img[off:off + len(old)] != old:
            sys.exit(f"0x{addr:08x}: expected {old.hex()}, found {img[off:off + len(old)].hex()} -- wrong image?")
        img[off:off + len(new)] = new
        print(f"0x{addr:08x}  {old.hex()} -> {new.hex()}  {why}")


def main():
    here = Path(__file__).resolve().parent
    root = here.parents[1]  # dev repo root (firmware/ lives there); patcher/src/ -> patcher/ -> root
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "firmware/decoded/zen_1.1.0.bin"
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else root / "firmware/patched/zen_1.1.0_patch1.bin"

    img = bytearray(src.read_bytes())
    if hashlib.sha256(img).hexdigest() != ORIG_SHA256:
        sys.exit(f"{src}: sha256 mismatch, not the original 1.1.0 image")

    apply(img, PATCHES + build_hooks(here, here / "build"))

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(img)
    print(f"-> {dst}  sha256 {hashlib.sha256(img).hexdigest()}")


if __name__ == "__main__":
    main()
