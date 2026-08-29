<!--
This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections. You can also include images in this folder and reference them in the markdown. Each image must be less
than 512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This is a 4-channel debounced wake/event controller.

Each of the 4 input channels (`thresh_in[3:0]`) is first double-flop synchronized onto the local clock, then run
through a per-channel digital debounce counter (depth `DB=8` clock cycles). A channel only becomes "stable" once
its input has held steady for 8 consecutive cycles while its enable bit (`ch_en[i]`) is set; any drop-out or
disabled channel resets that channel's debounce counter immediately.

A priority encoder reports the lowest-indexed active, debounced channel on `priority_ch` (3'd7 means "none active").

The core event-detection FSM supports two wake modes, selected by `mode_and`:

- **OR mode** (`mode_and = 0`): a wake pulse fires as soon as *any* enabled channel becomes stable.
- **AND mode** (`mode_and = 1`): a wake pulse only fires once *all* enabled channels are simultaneously stable.
  If channels assert and then drop out again before every enabled channel lines up, that partial assertion is
  logged as a "false wake" in `false_wake_cnt` instead of firing a real wake.

When a wake condition fires, `wake_out` pulses high for a fixed number of cycles (pulse width set by `PW=4`,
i.e. up to 16 cycles) and the saturating 16-bit `wake_count` increments once per real wake event (it holds at
`0xFFFF` instead of wrapping around).

Because the wide internal status registers (`wake_out`, `evt_flags[3:0]`, `priority_ch[2:0]`, the 16-bit
`wake_count`, and the 16-bit `false_wake_cnt`) don't fit in the 8 `uo_out` pins TinyTapeout gives every project,
they're exposed through a small byte-wide readback bus, selected by `reg_sel[2:0]` on the bidirectional pins:

| reg_sel | uo_out contents |
|---|---|
| 0 | `{wake_out, priority_ch[2:0], evt_flags[3:0]}` |
| 1 | `wake_count[7:0]` |
| 2 | `wake_count[15:8]` |
| 3 | `false_wake_cnt[7:0]` |
| 4 | `false_wake_cnt[15:8]` |
| 5-7 | `0x00` |

## How to test

1. Hold `rst_n` low for a few clock cycles, then release it.
2. Set `ch_en` (`ui_in[7:4]`) to enable the channels you want active, e.g. `4'b1111` for all 4.
3. Leave `mode_and` (`uio_in[0]`) at `0` for OR mode.
4. Drive `thresh_in` (`ui_in[3:0]`) high on one channel and hold it steady for at least 8 clock cycles.
5. Set `reg_sel` (`uio_in[3:1]`) to `0` and confirm `uo_out[7]` (`wake_out`) pulses high, `uo_out[6:4]` shows the
   firing channel's `priority_ch`, and `uo_out[3:0]` shows `evt_flags`.
6. Set `reg_sel` to `1`/`2` and confirm `wake_count` incremented by 1 (16-bit value split across the two reads).
7. Repeat with `mode_and = 1` and only assert a subset of enabled channels — confirm no `wake_count` increment
   but `false_wake_cnt` (via `reg_sel = 3`/`4`) increments once the partial assertion drops out.
8. Repeat with all enabled channels asserted simultaneously in AND mode and confirm `wake_count` increments
   exactly once even if you hold the inputs asserted for a long time (no double-firing).

## External hardware

None — this project only needs the TinyTapeout demo board's on-board switches/LEDs or a logic analyzer/microcontroller
driving `ui_in`/`uio_in` and reading `uo_out`. No external hardware is required.
