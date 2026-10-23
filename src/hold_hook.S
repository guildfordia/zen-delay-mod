@ Patch 1 step 2 — TAP button hold, decided by duration (spec revised 2026-10-16):
@   released between 1.5 s and 3 s  -> FREE (from TAP / SYNC), knob pickup so the delay does not jump
@   held 3 s (fired while held)     -> SYNC (from FREE / TAP), tempo = current delay, factor x1 until centre
@   LED feedback only when the gesture changes the state: 1 blink at 1.5 s (not in FREE), 2 at 3 s (not in SYNC)
@ A press shorter than 1.5 s is a tap (counted by the tap function when the button goes down).
@
@ Hooks the stock long-press block of FUN_0800b878 (0x0800b8e6..0x0800b947, fired at 1.5 s while held and toggled
@ SYNC <-> TAP): its first instruction becomes a jump here; the body lives in the free flash at the end of the image. Entry state (as the stock code): r4 = feedback-blink struct 0x2000bb1c
@ ([r4] = active, [r4+4] = start ms), r5 = base 0x2000a014. r0-r3 and r6 are free (r6 is restored by the epilogue).
@ Button state kept by FUN_0800b398: [base+0xd09] 0 released, 1 pressed, 2 long press consumed;
@ [base+0xc74] = press time (ms).

    .syntax unified
    .thumb

    .equ HOLD_STAGE,   0x2000bb3c       @ ours: 0 none, 1 past 1.5 s, 2 past 3 s (zeroed at boot, see patch1.py)
    .equ FREE_PICKUP,  0x20000001       @ stock: 0 = free delay waits for the knob to catch the current value
    .equ BTN,          0xd09
    .equ PRESS_MS,     0xc74
    .equ DELAY,        0x774            @ current delay, ms
    .equ TEMPO,        0x77c            @ beat, ms
    .equ MODE,         0x78d            @ 0 free, 1 tap, 2 sync
    .equ PICKUP,       0xd4c            @ 0 = factor forced x1 until the knob crosses the x1 zone
    .equ FREE,         0
    .equ SYNC,         2

@ ---- 0x0800b8e6: replaces `ldrb.w r0, [r5, #0xd09]` (4 bytes); the rest of the stock block becomes dead
    .section .hold_site, "ax"
    b.w     frz_led                     @ freeze LED cue first (all modes), then the hold logic

@ ---- Freeze LED cue (user 2026-10-23): while frozen (CC 22 byte >= 64, set by CC 22 or the double TAP), the TAP
@ LED blinks fast (64 ms on / 64 ms off) whatever the mode. Not frozen + FREE: LED forced off (so a release in
@ FREE does not leave it lit). TAP/SYNC are drawn by led_hook.S just before. The stock gesture-feedback blink
@ sequencer runs after the hold logic (0x0800b948) and still overrides during a gesture.
@ Reached at 0x0800b8e6 in every mode; r4/r5 as for `hold`, r0-r3 free, LR already saved by the stock prologue.
    .section .frzled, "ax"
    .thumb_func
frz_led:
    ldr     r0, =0x2000bb3c             @ CCRAM
    ldrb    r0, [r0, #6]                @ CC 22 value byte (freeze)
    ldr     r3, =0x40021818             @ GPIOG BSRR (TAP LED = PG13)
    cmp     r0, #64
    bhs     1f
    ldrb.w  r0, [r5, #MODE]
    cbnz    r0, 2f                      @ TAP / SYNC: leave led_hook's drawing alone
    mov.w   r2, #0x20000000             @ FREE, not frozen: off
    str     r2, [r3]
    b       2f
1:  bl      hal_gettick
    lsls    r0, r0, #25                 @ bit 6 of the ms counter -> 64 ms phases
    lsrs    r0, r0, #31
    lsls    r0, r0, #4                  @ 0 = on, 16 = off
    mov.w   r2, #0x2000
    lsls    r2, r2, r0
    ldr     r3, =0x40021818
    str     r2, [r3]
2:  b.w     hold
    .ltorg

@ ---- free flash at the end of the image (0x0801fdc4..0x0801ffff was 0xFF)
    .section .hold, "ax"
    .thumb_func
hold:
    bl      hal_gettick
    mov     r3, r0                      @ r3 = now (ms)
    ldr.w   r1, [r5, #PRESS_MS]
    subs    r2, r0, r1                  @ r2 = time since the press (meaningful while held)
    movw    r6, #:lower16:HOLD_STAGE
    movt    r6, #:upper16:HOLD_STAGE
    ldrb.w  r0, [r5, #BTN]
    cmp     r0, #1
    beq     pressed
    cmp     r0, #2
    beq     held_long

    @ ---- released: act only if the hold ended between 1.5 s and 3 s
    ldrb    r0, [r6]
    cmp     r0, #1
    bne     clear
    ldrb.w  r0, [r5, #MODE]
    cbz     r0, clear                   @ already FREE: nothing to do
    movs    r0, #FREE
    strb.w  r0, [r5, #MODE]
    mov.w   r1, #0x20000000
    strb    r0, [r1, #FREE_PICKUP - 0x20000000]   @ keep the current delay until the knob catches it
clear:
    movs    r0, #0
    strb    r0, [r6]
    b       done

    @ ---- held, below 1.5 s so far
pressed:
    movw    r1, #1501
    cmp     r2, r1
    bcc     done
    movs    r0, #2
    strb.w  r0, [r5, #BTN]              @ long press consumed (stock marker, keeps the button state machine happy)
    movs    r0, #1
    strb    r0, [r6]                    @ stage 1
    ldrb.w  r0, [r5, #MODE]
    cbz     r0, done                    @ FREE: releasing now changes nothing -> no blink
    sub.w   r0, r3, #400                @ start the stock 2-blink sequence 400 ms in -> only its 2nd blink
    b       blink

    @ ---- still held after 1.5 s
held_long:
    ldrb    r0, [r6]
    cmp     r0, #1
    bne     done                        @ 3 s already handled
    movw    r1, #3001
    cmp     r2, r1
    bcc     done
    movs    r0, #2
    strb    r0, [r6]                    @ stage 2: releasing later does nothing
    ldrb.w  r0, [r5, #MODE]
    cmp     r0, #SYNC
    beq     done                        @ already SYNC: no change, no blink
    ldr.w   r0, [r5, #DELAY]
    str.w   r0, [r5, #TEMPO]            @ tempo = current delay (no jump), clock takes over when it comes
    movs    r0, #SYNC
    strb.w  r0, [r5, #MODE]
    movs    r0, #0
    strb.w  r0, [r5, #PICKUP]           @ x1 until the knob crosses the centre
    mov     r0, r3                      @ full 2-blink sequence from now
blink:
    str     r0, [r4, #4]
    movs    r0, #1
    strb    r0, [r4]
done:
    b.w     blink_seq

@ ---- fixed addresses in the original image (labels only, 0 bytes)
    .section .ret_hold, "ax"            @ 0x0800b948: stock blink sequencer, then the function epilogue
    .thumb_func
blink_seq:
    .section .gettick, "ax"             @ 0x08011b4c: HAL_GetTick
    .thumb_func
hal_gettick:
