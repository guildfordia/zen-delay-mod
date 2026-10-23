@ TAP/SYNC division table with a dotted eighth (user 2026-10-23, option b: logical order on the knob).
@ Stock zones (FUN_0800b398, compare chains at 0x0800b5d6..0x0800b683):
@   /8 /6 /4 /3 /2 /1.5 x1 x1.5 x2 x3 x4 x6 x8
@ New zones (user 2026-10-23: symmetric), 13 EQUAL zones, x1 centred on noon, 6 mirrored values each side:
@   /8 /4 /3 /2 /1.5 /1.33 | x1 | x1.33 x1.5 x2 x3 x4 x8
@ /1.33 = x0.75 = dotted eighth (beat = quarter). The pickup still needs factors 1/1 (x1 zone).
@
@ Site 0x0800b5d6 (`uxth r1, r0` + half of `cmp.w`), reached with r0 = DELAY TIME pot (ADC) in TAP/SYNC:
@ b.w div_zones. The routine stores MULT at [base+0xd64] and leaves DIV in s0, exactly what the stock pickup
@ code at 0x0800b684 expects (it then stores DIV at [base+0xd68]). r8 = base, r0-r3 free.

    .syntax unified
    .thumb
    .fpu fpv4-sp-d16

    .section .div_site, "ax"
    b.w     div_zones

    .section .divz, "ax"
    .thumb_func
div_zones:
    uxth    r1, r0
    adr     r2, zones
1:  ldrh    r3, [r2]
    cmp     r1, r3
    blo     2f
    adds    r2, #12
    b       1b
2:  vldr    s0, [r2, #4]                @ MULT
    addw    r3, r8, #0xd64
    vstr    s0, [r3]
    vldr    s0, [r2, #8]                @ DIV, for the stock pickup code
    b.w     div_ret
    .align  2
zones:                                  @ upper bound (exclusive, ADC), pad, MULT, DIV - 13 equal zones (~315 counts)
    .short  0x013b, 0
    .float  1, 8        @ /8
    .short  0x0276, 0
    .float  1, 4        @ /4
    .short  0x03b1, 0
    .float  1, 3        @ /3
    .short  0x04ec, 0
    .float  1, 2        @ /2
    .short  0x0627, 0
    .float  1, 1.5        @ /1.5
    .short  0x0762, 0
    .float  0.75, 1        @ /1.33 (dotted eighth)
    .short  0x089e, 0
    .float  1, 1        @ x1 (noon)
    .short  0x09d9, 0
    .float  1.3333333333333333, 1        @ x1.33
    .short  0x0b14, 0
    .float  1.5, 1        @ x1.5
    .short  0x0c4f, 0
    .float  2, 1        @ x2
    .short  0x0d8a, 0
    .float  3, 1        @ x3
    .short  0x0ec5, 0
    .float  4, 1        @ x4
    .short  0xffff, 0
    .float  8, 1        @ x8

    .section .div_ret, "ax"
div_ret:
