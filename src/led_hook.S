@ TAP LED per mode (user, 2026-10-23):
@   FREE: off (stock: the blink block is skipped in FREE, see patch1.py 0x0800b888)
@   TAP : short flash (FLASH_MS) at the start of each beat of the tapped tempo
@   SYNC: on, with a FLASH_MS blackout on each beat RECEIVED from the MIDI clock
@         (clock parser timestamp) -> if the clock stops, the LED stays steadily on
@
@ Replaces the stock 50 % tempo blink (0x0800b8b4..0x0800b8e5 in FUN_0800b878). Entry state there:
@ r1 = now (ms), r5 = base 0x2000a014, r6 = 0x40021810 (GPIOG IDR; [r6, #8] = BSRR, LED = pin 13:
@ 0x2000 = on, 0x20000000 = off), r4 = feedback-blink struct (untouched). r0, r2, r3 are free.
@ Leaves to 0x0800b8e6 (= b.w hold, the hold hook), exactly where the stock blink ended.

    .syntax unified
    .thumb

    .equ MODE,      0x78d               @ 0 free, 1 tap, 2 sync
    .equ TEMPO,     0x77c               @ beat, ms
    .equ TAP_BEAT,  0xda0               @ stock "last blink toggle" time, reused as last TAP beat (ms)
    .equ CLK_STATE, 0x2000bb04          @ MIDI clock parser state: [+8] = time of the last full beat (24 ticks)
    .equ FLASH_MS,  80
    .equ SYNC,      2

@ ---- 0x0800b8b4: replaces `ldr.w r0, [r5, #0xda0]` (4 bytes); the rest of the stock blink becomes dead
    .section .led_site, "ax"
    b.w     led

@ ---- 0x0800b8ea..0x0800b947: stock 1.5 s long-press block, dead since hold_hook.S
    .section .led, "ax"
    .thumb_func
led:
    ldrb.w  r3, [r5, #MODE]
    cmp     r3, #SYNC
    beq     1f
    @ TAP: internal beat from the tapped tempo
    ldr.w   r0, [r5, #TAP_BEAT]
    ldr.w   r2, [r5, #TEMPO]
    subs    r0, r1, r0                  @ r0 = ms since the last beat
    cmp     r0, r2
    itt     hs
    strhs.w r1, [r5, #TAP_BEAT]         @ a new beat starts now
    movhs   r0, #0
    b       2f
1:  @ SYNC: beat = last full beat measured by the MIDI clock parser
    ldr     r2, =CLK_STATE
    ldr     r0, [r2, #8]
    subs    r0, r1, r0
2:  @ r0 = ms since the beat -> BSRR shift: 0 = LED on, 16 = LED off
    cmp     r0, #FLASH_MS
    ite     lo
    movlo   r0, #0                      @ inside the flash window: on
    movhs   r0, #16                     @ outside: off
    cmp     r3, #SYNC
    it      eq
    rsbeq   r0, r0, #16                 @ SYNC: inverted (on, blackout on the beat)
    mov.w   r2, #0x2000
    lsls    r2, r2, r0
    str     r2, [r6, #8]
    b.w     ret_led
    .ltorg

    .section .ret_led, "ax"
ret_led:
