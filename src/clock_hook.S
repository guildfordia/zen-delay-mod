@ Patch 1 — MIDI clock only counts in SYNC mode.
@
@ Hook site: FUN_0800bb3c (MIDI realtime parser), right after a full beat (24 x 0xF8) was measured
@ and found < 3000 ms. Originally it sets the "new period" flag [base+0x9b5] and stores the period
@ in [base+0x9a4] (both through the pointer [base+0xda8] = base+0x8d4), then returns.
@ The control routine then copies that period into the tempo [base+0x77c] (0x0800b6c6), in TAP and SYNC
@ alike since TAP uses the division table: without this hook a running clock would overwrite a tapped tempo.
@
@ Only button gestures change the mode (spec, revised 2026-10-16): this hook never touches it.
@
@ At this point: r4 = base (0x2000a014), [sp] = measured beat period in ms. r0-r1 are free.

    .syntax unified
    .thumb

    .equ MODE,         0x78d            @ [base+0x78d]: 0 free, 1 tap, 2 sync
    .equ SYNC,         2

@ ---- 0x0800bb76: replaces `ldr.w r0, [r4, #0xda8]` (4 bytes)
    .section .site, "ax"
    b.w     clock_hook

@ ---- free room: old tap branch of FUN_0800b398 (dead since the tap -> division table patch)
    .section .hook, "ax"
    .thumb_func
clock_hook:
    ldrb.w  r1, [r4, #MODE]
    cmp     r1, #SYNC
    bne     done                        @ FREE / TAP: drop this beat, the tempo is not touched

    @ SYNC: what the original code did
    ldr.w   r0, [r4, #0xda8]
    movs    r1, #1
    strb.w  r1, [r0, #0xe1]             @ new-period flag  [base+0x9b5] = 1
    ldr     r1, [sp]
    str.w   r1, [r0, #0xd0]             @ period           [base+0x9a4] = measured ms

done:
    b.w     clock_return

@ ---- 0x0800bb8a: original epilogue of FUN_0800bb3c (add sp,#4 / pop {r4,r5,pc}), not modified.
@ An empty section only gives the linker a Thumb label at a fixed address to branch back to.
    .section .ret_clock, "ax"
    .thumb_func
clock_return:
