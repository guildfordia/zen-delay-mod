@ FREEZE from the pedal: a very fast double TAP (second press < DBL_MS = 250 ms after the first; tap tempo therefore >= 250 ms per tap, faster delays via the divisions) toggles the freeze
@ (user choice 2026-10-23, option A: TAP + BYPASS is impossible, BYPASS is switched in hardware).
@ Works with the TAP button and the TAP footswitch (both go through the stock tap function FUN_0800b9a8).
@ "Last touched wins" with CC 22: the gesture writes the CC 22 value byte (0 or 127) that send_hook.S reads.
@
@ Site: 0x0800ba0c in FUN_0800b9a8, right after the stock code computed r2 = ms since the previous tap
@ (r1 = now, r5 = base) and flashed the TAP LED. The stock instruction there, `movw r0, #0xbb8` (3000 ms, the
@ "new tempo" pause), becomes a jump here. A double tap leaves through the stock 0x0800baae path
@ ([base+0xd50] = 1: the next tap starts a fresh tempo, mode and tempo untouched). Otherwise: back to 0x0800ba10.
@ Lower bound DBL_MIN_MS: below it the second "press" is contact bounce, handled as before by the stock code.

    .syntax unified
    .thumb

    .equ CCRAM,        0x2000bb3c
    .equ CC22_VALUE,   4 + 22 - 20       @ VALUES + index of CC 22
    .equ DBL_MS,       250             @ user 2026-10-23: 150 was too tight for a natural double tap
    .equ DBL_MIN_MS,   30

    .section .dbl_site, "ax"
    b.w     dbl_tap

    .section .dbl, "ax"
    .thumb_func
dbl_tap:
    cmp     r2, #DBL_MS
    bhs     1f
    cmp     r2, #DBL_MIN_MS
    blo     1f
    ldr     r0, =CCRAM
    ldrb    r3, [r0, #CC22_VALUE]
    cmp     r3, #64
    ite     hs
    movhs   r3, #0                      @ frozen -> release
    movlo   r3, #127                    @ not frozen -> freeze
    strb    r3, [r0, #CC22_VALUE]
    b.w     tap_fresh_exit              @ stock: [base+0xd50] = 1, return
1:  movw    r0, #0xbb8                  @ the replaced instruction
    b.w     ret_dbl
    .ltorg

    .section .ret_dbl, "ax"
ret_dbl:
    .section .tap_fresh_exit, "ax"
tap_fresh_exit:
