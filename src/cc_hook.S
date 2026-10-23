@ Patch 2 — MIDI CC on channel 16. CC-1: message reader, CC 20 FEEDBACK, CC 23 DELAY TIME.
@ CC-2: CC 24 DELAY MODE (algorithm switch override), CC 25 TAP, CC 26 MODE (FREE / TAP / SYNC).
@ Behaviour: see README.md.
@
@ 1) midi_rx replaces the entry of FUN_0800bb3c, the UART RX-complete callback (USART1 IRQ, one byte per call,
@    byte at [base+0x974]). Realtime bytes (>= 0xF8: clock, start, stop...) go back to the stock parser; the others
@    feed a small channel-message reader. It only STORES the CC (value + "new" flag): we are inside an interrupt.
@ 2) cc_apply replaces the call to the pot filter FUN_0800c86c in the control routine (TIM2). It runs the filter,
@    then writes each new CC over the filtered pot value (float[] at base+0xd54). The filter only rewrites that value
@    while the knob is being moved -> "last touched wins" comes for free.

    .syntax unified
    .thumb

    .equ BASE,         0x2000a014
    .equ RX_BYTE,      0x974            @ byte just received (stock)
    .equ POT_VALUES,   0xd54            @ float[] filtered pot values (stock)
    .equ SLOT_FEEDBACK, 0xd70           @ index of the FEEDBACK pot in POT_VALUES (ADC slot 9)
    .equ SLOT_TIME,    0xd78            @ index of the DELAY TIME pot (ADC slot 10)
    .equ PICKUP,       0xd4c            @ TAP/SYNC: 0 = factor forced x1 until the knob crosses the centre
    .equ FREE_PICKUP,  0x20000001       @ FREE: 0 = delay held until the knob catches it
    .equ ALGO,         0x78c            @ delay algorithm from the DELAY MODE switch: 0 / 1 / 2 (2 = delay off)
    .equ ALGO_SUB,     0xc5c            @ second bit of the algorithm (0 / 1)
    .equ DELAY,        0x774            @ current delay, ms
    .equ TEMPO,        0x77c            @ beat, ms
    .equ MODE,         0x78d            @ 0 free, 1 tap, 2 sync

    @ RAM, zeroed at boot (zero-init area extended up to 0x2000bb60, see patch1.py)
    .equ CCRAM,        0x2000bb3c       @ +0 is HOLD_STAGE (hold_hook.S)
    .equ STATUS,       1                @ running status (0 = none / ignore data bytes)
    .equ DATA1,        2                @ first data byte (controller number)
    .equ COUNT,        3                @ data bytes received for the current CC (0 or 1)
    .equ VALUES,       4                @ u8[7]: CC 20..26 values
    .equ SW_LAST,      11               @ last DELAY MODE switch position seen (0x80 | code), to detect a move
    .equ FLAGS,        12               @ u8[7]: 1 = new value not applied yet (one byte each: written in two IRQs)
    .equ ALGO_CC,      19               @ 0 = switch rules, else 0x80 | code set by CC 24 (until the switch moves)
    .equ FIRST_CC,     20
    .equ NUM_CC,       7
    @ Everything stays inside 0x2000bb3c..0x2000bb4f: writing 0x2000bb50 broke the delay output on the hardware
    @ (2026-10-19, found by bisection + emulation; who reads it is still unknown).
    .equ CC_STATUS,    0xBF             @ Control Change on channel 16

@ ---- 0x0800bb3c: replaces `push {r4,r5,lr}` + the first half of `ldr.w r4, =base` (never executed any more)
    .section .midi_site, "ax"
    b.w     midi_rx

@ ---- 0x0800b4d0: replaces `bl 0x0800c86c` (pot filter), r0 = &POT_VALUES is passed through
    .section .potf_site, "ax"
    bl      cc_apply

@ ---- DELAY MODE switch override. Called by cc_apply, i.e. right after the stock switch decode wrote ALGO / ALGO_SUB,
@ in the same TIM2 interrupt (the DSP main loop cannot run in between). r5 = BASE.
@ (First version was called from the decode itself, a `bl` at 0x0800b4c8: on the hardware the Zen then came up
@ with no delay output and TAP blinking slowly; not understood yet, emulation found nothing. Moved here instead.)
@ Position code: 0..3 = algo * 2 + sub (algo 0 = tape, 1 = digital; sub 1 = ping-pong), 4 = delay off (algo 2). Last touched wins: a CC 24 sets the
@ code until the physical switch moves.
@ Lives in the free flash at the end of the image, right after .cc.
    .section .algo, "ax"
    .thumb_func
algo_override:
    ldrb.w  r0, [r5, #ALGO]
    ldrb.w  r1, [r5, #ALGO_SUB]
    cmp     r0, #2
    ite     eq
    moveq   r2, #4
    addne.w r2, r1, r0, lsl #1
    orr     r2, r2, #0x80               @ code seen on the switch (0x80 so that 0 means "never seen")
    movw    r3, #:lower16:CCRAM
    movt    r3, #:upper16:CCRAM
    ldrb    r1, [r3, #SW_LAST]
    cmp     r1, r2
    beq     1f
    strb    r2, [r3, #SW_LAST]          @ the switch moved (or first pass): it takes over again
    movs    r1, #0
    strb    r1, [r3, #ALGO_CC]
1:  ldrb    r1, [r3, #FLAGS + 24 - FIRST_CC]
    cbz     r1, 2f
    movs    r1, #0
    strb    r1, [r3, #FLAGS + 24 - FIRST_CC]
    ldrb    r1, [r3, #VALUES + 24 - FIRST_CC]
    add.w   r1, r1, r1, lsl #2
    lsrs    r1, r1, #7                  @ zone 0..4 = value * 5 / 128
    adr     r2, zone_code
    ldrb    r1, [r2, r1]
    orr     r1, r1, #0x80
    strb    r1, [r3, #ALGO_CC]
2:  ldrb    r1, [r3, #ALGO_CC]
    cbz     r1, 3f
    and     r1, r1, #7
    cmp     r1, #4
    beq     4f
    and     r2, r1, #1
    strb.w  r2, [r5, #ALGO_SUB]
    lsrs    r0, r1, #1
    b       5f
4:  movs    r0, #2
5:  strb.w  r0, [r5, #ALGO]
3:  bx      lr
zone_code:                              @ CC 24 zone -> position code, in the switch order (measured 2026-10-20):
    .byte   4, 0, 1, 3, 2               @ off, tape, tape pingpong, digital pingpong, digital (vintage = analog loop)

@ ---- CC 25: one tap. Enters the stock tap function right after its "is the button pressed?" test, with the
@ registers its prologue sets up (r4 = 0x2000b290, r5 = BASE, r6 = GPIOD IDR). It returns to our caller.
@ Lives in the dead old tap branch of FUN_0800b398 (0x0800b57a.., after clock_hook).
    .section .tap, "ax"
    .thumb_func
tap_now:
    push    {r4, r5, r6, lr}
    sub     sp, #8
    movw    r4, #0xb290
    movt    r4, #0x2000
    movw    r5, #:lower16:BASE
    movt    r5, #:upper16:BASE
    movw    r6, #0x0c10
    movt    r6, #0x4002
    b.w     tap_body

    .section .cc, "ax"
    .thumb_func
midi_rx:
    movw    r3, #:lower16:BASE
    movt    r3, #:upper16:BASE
    ldrb.w  r0, [r3, #RX_BYTE]
    cmp     r0, #0xF8
    bhs     realtime                    @ clock & co: may arrive in the middle of a message, never touch our state
    movw    r2, #:lower16:CCRAM
    movt    r2, #:upper16:CCRAM
    cmp     r0, #0xF0
    bhs     syscommon
    tst     r0, #0x80
    bne     status

    @ data byte
    ldrb    r1, [r2, #STATUS]
    cmp     r1, #CC_STATUS
    bne     done                        @ another channel / message type: ignore
    ldrb    r1, [r2, #COUNT]
    cbnz    r1, second
    strb    r0, [r2, #DATA1]            @ controller number
    movs    r1, #1
    strb    r1, [r2, #COUNT]
    bx      lr
second:
    movs    r1, #0
    strb    r1, [r2, #COUNT]            @ ready for the next CC (running status)
    ldrb    r1, [r2, #DATA1]
    subs    r1, #FIRST_CC
    cmp     r1, #NUM_CC
    bhs     done                        @ not one of ours (unsigned: also below 20)
    add     r1, r2
    strb    r0, [r1, #VALUES]
    movs    r0, #1
    strb    r0, [r1, #FLAGS]
done:
    bx      lr

status:                                 @ 0x80..0xEF: new channel message
    strb    r0, [r2, #STATUS]
    movs    r0, #0
    strb    r0, [r2, #COUNT]
    bx      lr

syscommon:                              @ 0xF0..0xF7 (sysex...): cancels running status, data bytes ignored
    movs    r0, #0
    strb    r0, [r2, #STATUS]
    bx      lr

realtime:                               @ what the two replaced instructions did, then the stock parser
    push    {r4, r5, lr}
    mov     r4, r3
    b.w     midi_rt

@ ---------------------------------------------------------------------------------------------------------
    .thumb_func
cc_apply:
    push    {r4, r5, r6, lr}
    bl      pot_filter                  @ stock: r0 = &POT_VALUES
    movw    r4, #:lower16:CCRAM
    movt    r4, #:upper16:CCRAM
    movw    r5, #:lower16:BASE
    movt    r5, #:upper16:BASE
    bl      algo_override               @ CC 24 / DELAY MODE switch
    bl      send_cc                     @ CC 21 / INPUT SEND target (send_hook.S)

    @ CC 20 -> FEEDBACK
    ldrb    r0, [r4, #FLAGS + 20 - FIRST_CC]
    cbz     r0, 1f
    movs    r0, #0
    strb    r0, [r4, #FLAGS + 20 - FIRST_CC]
    ldrb    r0, [r4, #VALUES + 20 - FIRST_CC]
    ldr.w   r1, [r5, #SLOT_FEEDBACK]
    bl      set_pot
1:
    @ CC 23 -> DELAY TIME
    ldrb    r0, [r4, #FLAGS + 23 - FIRST_CC]
    cbz     r0, 2f
    movs    r0, #0
    strb    r0, [r4, #FLAGS + 23 - FIRST_CC]
    ldrb    r0, [r4, #VALUES + 23 - FIRST_CC]
    ldr.w   r1, [r5, #SLOT_TIME]
    bl      set_pot
    movs    r0, #1                      @ a CC is an explicit choice: release both pickups right away
    strb.w  r0, [r5, #PICKUP]
    mov.w   r1, #0x20000000
    strb    r0, [r1, #FREE_PICKUP - 0x20000000]
2:
    @ CC 25 -> one tap (value > 0)
    ldrb    r0, [r4, #FLAGS + 25 - FIRST_CC]
    cbz     r0, 3f
    movs    r0, #0
    strb    r0, [r4, #FLAGS + 25 - FIRST_CC]
    ldrb    r0, [r4, #VALUES + 25 - FIRST_CC]
    cbz     r0, 3f
    bl      tap_now
3:
    @ CC 26 -> mode: 0..42 FREE, 43..85 TAP, 86..127 SYNC; acts only if it differs from the current mode
    ldrb    r0, [r4, #FLAGS + 26 - FIRST_CC]
    cbz     r0, 9f
    movs    r0, #0
    strb    r0, [r4, #FLAGS + 26 - FIRST_CC]
    ldrb    r0, [r4, #VALUES + 26 - FIRST_CC]
    movs    r6, #0
    cmp     r0, #43
    it      hs
    movhs   r6, #1
    cmp     r0, #86
    it      hs
    movhs   r6, #2                      @ r6 = wanted mode
    ldrb.w  r1, [r5, #MODE]             @ r1 = current mode
    cmp     r1, r6
    beq     9f
    cbnz    r6, 5f
    @ -> FREE (like the 1.5 s hold): keep the current delay until the knob catches it
    strb.w  r6, [r5, #MODE]
    mov.w   r1, #0x20000000
    strb    r6, [r1, #FREE_PICKUP - 0x20000000]
    b       9f
5:  cmp     r6, #1
    bne     6f
    @ -> TAP: from SYNC keep the tempo and the division (stop following the clock);
    @    from FREE start from the current delay, factor x1 (no jump)
    strb.w  r6, [r5, #MODE]
    cmp     r1, #2
    beq     9f
    b       7f
    @ -> SYNC (like the 3 s hold): tempo = current delay, factor x1, the clock takes over
6:  strb.w  r6, [r5, #MODE]
7:  ldr.w   r0, [r5, #DELAY]
    str.w   r0, [r5, #TEMPO]
    movs    r0, #0
    strb.w  r0, [r5, #PICKUP]
9:
    pop     {r4, r5, r6, pc}

@ r0 = CC value 0..127, r1 = pot slot index, r5 = BASE: POT_VALUES[r1] = r0 * 4094 / 127
@ (4094, not 4095: the last entry of the free-mode delay table is 10 s, the knob itself stops around 4093 = 2.99 s)
set_pot:
    vmov    s0, r0
    vcvt.f32.u32 s0, s0
    vldr    s1, scale
    vmul.f32 s0, s0, s1
    addw    r2, r5, #POT_VALUES
    add.w   r2, r2, r1, lsl #2
    vstr    s0, [r2]
    bx      lr
    .align  2
scale:
    .float  32.236220                   @ 4094 / 127

@ ---- fixed addresses in the original image (labels only, 0 bytes)
    .section .ret_midi, "ax"            @ 0x0800bb42: stock parser right after its two first instructions
    .thumb_func
midi_rt:
    .section .pot_filter, "ax"          @ 0x0800c86c: stock pot filter
    .thumb_func
pot_filter:
    .section .tap_body, "ax"            @ 0x0800b9d6: stock tap function, right after the button test
    .thumb_func
tap_body:
