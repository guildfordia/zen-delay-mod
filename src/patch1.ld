/* Patch 1: places each hook section at its absolute flash address in the original image. */

SECTIONS
{
    .site 0x0800bb76 : { *(.site) }
    .hook 0x0800b55e : { *(.hook) }               /* dead code up to 0x0800b5d0 */
    .hold_site 0x0800b8e6 : { *(.hold_site) }     /* first instruction of the stock long-press block */
    .hold 0x0801fdc4 : { *(.hold) }               /* free flash at the end of the image (was 0xFF) */
    .midi_site 0x0800bb3c : { *(.midi_site) }     /* entry of the MIDI RX callback FUN_0800bb3c */
    .potf_site 0x0800b4d0 : { *(.potf_site) }     /* call to the pot filter in the control routine */
    .cc 0x0801fe60 : { *(.cc) }                   /* free flash, after .hold */
    .algo ALIGN(ADDR(.cc) + SIZEOF(.cc), 4) : { *(.algo) }   /* right after .cc, free flash */
    .tap 0x0800b57a : { *(.tap) }                 /* dead old tap branch, after .hook */
    .led_site 0x0800b8b4 : { *(.led_site) }       /* stock TAP LED blink in FUN_0800b878 */
    .led 0x0800b8ea : { *(.led) }                 /* dead stock long-press block, up to 0x0800b948 */
    .send_site 0x08008f5c : { *(.send_site) }     /* DSP: right after the input samples are stored */
    .send 0x080135d4 : { *(.send) }               /* freed debug printf body, up to 0x08013a64 */
    .ret_send 0x08008f60 : { *(.ret_send) }
    .dbl_site 0x0800ba0c : { *(.dbl_site) }       /* tap function, after the interval since the previous tap */
    .dbl 0x08013700 : { *(.dbl) }                 /* freed printf body, after .send */
    .frzled 0x08013730 : { *(.frzled) }           /* freeze LED cue, before the hold logic */
    .div_site 0x0800b5d6 : { *(.div_site) }       /* TAP/SYNC division chain (stock compare chains) */
    .divz 0x08013770 : { *(.divz) }               /* table-driven divisions incl. x0.75 */
    .div_ret 0x0800b684 : { *(.div_ret) }         /* stock pickup code: s0 = DIV */
    .ret_dbl 0x0800ba10 : { *(.ret_dbl) }
    .tap_fresh_exit 0x0800baae : { *(.tap_fresh_exit) }
    .ret_clock 0x0800bb8a : { *(.ret_clock) }     /* labels only, 0 bytes */
    .ret_led 0x0800b8e6 : { *(.ret_led) }
    .ret_midi 0x0800bb42 : { *(.ret_midi) }
    .pot_filter 0x0800c86c : { *(.pot_filter) }
    .tap_body 0x0800b9d6 : { *(.tap_body) }
    .ret_hold 0x0800b948 : { *(.ret_hold) }
    .gettick 0x08011b4c : { *(.gettick) }
    /DISCARD/ : { *(*) }
}
