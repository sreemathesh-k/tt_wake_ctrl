<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

`wake_controller` monitors 4 input channels through:

1. A 2-flop synchronizer on `thresh_in`.
2. A per-channel debounce counter (`DB` cycles) — a channel only becomes
   "stable" once continuously asserted (and enabled via `ch_en`) for the
   full debounce window.
3. A priority encoder reporting the lowest-numbered active, enabled channel
   (`priority_ch = 7` means none active).
4. An event FSM with two modes, selected by `mode_and`:
   - **OR mode** (`mode_and=0`): any enabled channel going stable fires a
     wake event.
   - **AND mode** (`mode_and=1`): a wake only fires once *all* enabled
     channels are simultaneously stable. A partial assertion that later
     drops out increments `false_wake_cnt` instead of firing.
5. A fixed-width output pulse (`PW` cycles) and a saturating 16-bit
   `wake_count`.

Because a TinyTapeout tile only exposes 8 dedicated outputs, the wide
`wake_count` / `false_wake_cnt` registers and the status bits
(`wake_out`, `priority_ch`, `evt_flags`) are exposed through a small
byte-wide readback bus on `uo_out`, selected by a 3-bit `reg_sel` field
driven from the bidirectional pins.

### Register map (select via `uio_in[3:1]`, read from `uo_out`)

| reg_sel | uo_out contents                                |
|---------|-------------------------------------------------|
| 0       | `{wake_out, priority_ch[2:0], evt_flags[3:0]}`   |
| 1       | `wake_count[7:0]`                                |
| 2       | `wake_count[15:8]`                               |
| 3       | `false_wake_cnt[7:0]`                            |
| 4       | `false_wake_cnt[15:8]`                           |
| 5-7     | reads back `0x00`                                |

## How to test

1. Drive `ui_in[3:0]` = `thresh_in`, `ui_in[7:4]` = `ch_en`.
2. Set `uio_in[0]` to choose OR (`0`) or AND (`1`) mode.
3. Hold a pattern steady for at least the debounce window (8 clock
   cycles by default) so it registers as "stable".
4. Set `uio_in[3:1] = 0` and read `uo_out` for live status
   (`wake_out`, `priority_ch`, `evt_flags`).
5. Cycle `uio_in[3:1]` through `1`-`4` to read the 16-bit `wake_count`
   and `false_wake_cnt` registers a byte at a time.
6. See `test/test.py` for a scripted cocotb example covering reset,
   glitch rejection, OR-mode wake, and AND-mode true/false wake
   behaviour.

## External hardware

None — only the standard TinyTapeout dedicated/bidirectional pins
described above are used.

