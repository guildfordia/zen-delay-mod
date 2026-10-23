@ CC 21 — INPUT SEND + CC 22 — FREEZE.
@ CC 21 — INPUT SEND ("throws"): a gain on the delay INPUT only (the dry path is analog and untouched),
@ so the repeats keep going when the send is closed. 0 = closed, 127 = open (default at power-on).
@ Gain curve: (value / 127)^2. Smoothed per sample (one-pole, k = 1/256,
@ ~5 ms at 48 kHz) so throws do not click.
@
@ 1) send_site: FUN_08008e20 (DSP, once per stereo sample, main loop) has just converted the codec input and
@    stored it: L at [base+0xd0c] (still in s0), R at [base+0xd10] (still in s1); every delay algorithm reads
@    these (and the "delay off" branch writes s0/s1 straight to the output). The next stock instruction,
@    `ldrb.w r0, [r8, #0x78c]` at 0x08008f5c, becomes a jump to send_hook, which scales memory and s0/s1,
@    runs the replaced instruction and jumps back to 0x08008f60. Everything else is preserved.
@ 2) send_cc: called by cc_apply (TIM2 interrupt, control rate) when a CC 21 arrived: new target gain.
@
@ State in CCM RAM (free above the 8 KB stack at 0x10000000..0x10002000, no other reference in the image).
@ CCM is NOT zeroed at boot: a magic word marks it valid; without it the hook starts at gain 1.0 (open).
@ Code lives in the freed debug-printf body at 0x080135d4 (see patch1.py). NOT in FUN_0801620c: that one is the
@ boot RAM initializer, reached through a relative offset in the init table (2026-10-23, silent delay).

    .syntax unified
    .thumb
    .fpu fpv4-sp-d16

    .equ SEND_STATE,   0x10008000       @ +0 magic, +4 target gain (float), +8 current gain (float)
    .equ MAGIC,        0x53454E44       @ "SEND"
    .equ CCRAM,        0x2000bb3c
    .equ VALUES,       4
    .equ FLAGS,        12
    .equ CC_SEND,      21 - 20          @ index of CC 21 in VALUES / FLAGS
    .equ CC_FREEZE,    22 - 20          @ index of CC 22: raw value, zero at boot -> freeze off

@ ---- 0x08008f5c: replaces `ldrb.w r0, [r8, #0x78c]` (4 bytes)
    .section .send_site, "ax"
    b.w     send_hook

    .section .send, "ax"
    .thumb_func
send_hook:
    push    {r1, r2}
    vpush   {s2-s4}
    ldr     r1, =SEND_STATE
    ldr     r2, [r1]
    ldr     r0, =MAGIC
    cmp     r2, r0
    beq     1f
    str     r0, [r1]                    @ first pass since power-on: open
    mov.w   r2, #0x3f800000             @ 1.0f
    str     r2, [r1, #4]
    str     r2, [r1, #8]
1:  vldr    s2, [r1, #4]                @ target
    @ CC 22 FREEZE (>= 64): input closed and feedback forced to exactly 1.0 (both DSP algorithms read [base+0xc58],
    @ rewritten from the FEEDBACK knob by the control routine at every pass -> overriding it here, per sample,
    @ always wins; on release the knob value comes back by itself). The stock 1000-sample feedback smoothing
    @ (state at 0x2000bb30) glides to 1.0 in ~20 ms.
    ldr     r2, =CCRAM
    ldrb    r2, [r2, #VALUES + CC_FREEZE]
    cmp     r2, #64
    blo     2f
    movs    r2, #0
    vmov    s2, r2                      @ target gain 0 while frozen (the CC 21 target is kept for the release)
    mov.w   r2, #0x3f800000
    str.w   r2, [r8, #0xc58]            @ feedback = 1.0
2:  vldr    s3, [r1, #8]                @ current
    vsub.f32 s2, s2, s3
    vldr    s4, .Lk
    vmla.f32 s3, s2, s4                 @ current += (target - current) / 256
    vstr    s3, [r1, #8]
    vmul.f32 s0, s0, s3                 @ L in register
    vmul.f32 s1, s1, s3                 @ R in register
    addw    r1, r8, #0xd0c
    vstr    s0, [r1]                    @ L in memory
    vstr    s1, [r1, #4]                @ R in memory (0xd10)
    vpop    {s2-s4}
    pop     {r1, r2}
    ldrb.w  r0, [r8, #0x78c]            @ the replaced instruction
    b.w     ret_send
    .align  2
.Lk:
    .float  0.00390625

@ cc_apply context: r4 = CCRAM. r0-r3 and s0-s15 are free (interrupt: the FPU context is stacked by hardware).
    .thumb_func
send_cc:
    ldrb    r0, [r4, #FLAGS + CC_SEND]
    cbz     r0, 9f
    movs    r0, #0
    strb    r0, [r4, #FLAGS + CC_SEND]
    ldrb    r0, [r4, #VALUES + CC_SEND]
    vmov    s0, r0
    vcvt.f32.u32 s0, s0
    vldr    s1, .Linv127
    vmul.f32 s0, s0, s1
    vmul.f32 s0, s0, s0                 @ (v / 127)^2
    ldr     r1, =SEND_STATE
    ldr     r2, [r1]
    ldr     r3, =MAGIC
    cmp     r2, r3
    beq     1f
    str     r3, [r1]                    @ CC before the first DSP pass: start the current gain at 1.0
    mov.w   r2, #0x3f800000
    str     r2, [r1, #8]
1:  vstr    s0, [r1, #4]
9:  bx      lr
    .align  2
.Linv127:
    .float  0.007874015748031496
    .ltorg
    .global send_cc

    .section .ret_send, "ax"
ret_send:
