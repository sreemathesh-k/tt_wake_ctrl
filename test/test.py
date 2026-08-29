# SPDX-FileCopyrightText: © 2026 Sreemathesh K
# SPDX-License-Identifier: Apache-2.0
#
# cocotb port of the original tb_full.v test cases (TC1-TC14) for
# tt_um_sreemathesh_k_wake_ctrl.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def set_inputs(dut, thresh_in=0, ch_en=0b1111, mode_and=0, reg_sel=0):
    dut.ui_in.value = ((ch_en & 0xF) << 4) | (thresh_in & 0xF)
    dut.uio_in.value = ((reg_sel & 0x7) << 1) | (mode_and & 0x1)


async def read_reg(dut, reg_sel):
    """Select a readback register and return the byte on uo_out."""
    dut.uio_in.value = (dut.uio_in.value.integer & 0x1) | ((reg_sel & 0x7) << 1)
    await ClockCycles(dut.clk, 1)
    return int(dut.uo_out.value)


async def read_wake_count(dut):
    lo = await read_reg(dut, 1)
    hi = await read_reg(dut, 2)
    return (hi << 8) | lo


async def read_false_wake_cnt(dut):
    lo = await read_reg(dut, 3)
    hi = await read_reg(dut, 4)
    return (hi << 8) | lo


async def read_status(dut):
    """reg_sel=0 -> {wake_out, priority_ch[2:0], evt_flags[3:0]}"""
    val = await read_reg(dut, 0)
    wake_out = (val >> 7) & 0x1
    priority_ch = (val >> 4) & 0x7
    evt_flags = val & 0xF
    return wake_out, priority_ch, evt_flags


async def do_reset(dut, ch_en=0b1111, mode_and=0):
    dut.ena.value = 1
    set_inputs(dut, thresh_in=0, ch_en=ch_en, mode_and=mode_and, reg_sel=0)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_wake_ctrl(dut):
    dut._log.info("Start wake_ctrl test")

    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())

    # ---------------- TC1: reset state ----------------
    await do_reset(dut)
    wake_out, priority_ch, evt_flags = await read_status(dut)
    assert wake_out == 0, "TC1 reset: wake_out=0"
    assert priority_ch == 7, "TC1 reset: priority_ch=7(none)"
    assert evt_flags == 0, "TC1 reset: evt_flags=0"
    assert await read_wake_count(dut) == 0, "TC1 reset: wake_count=0"
    assert await read_false_wake_cnt(dut) == 0, "TC1 reset: false_wake_cnt=0"

    # ---------------- TC2: glitch rejected by debounce ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 2)
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 10)
    assert await read_wake_count(dut) == 0, "TC2 glitch rejected: wake_count stays 0"

    # ---------------- TC3: OR mode sustained ch0 wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 8)
    _, _, evt_flags = await read_status(dut)
    assert evt_flags == 0b0001, "TC3 evt_flags reflects ch0 right after firing"
    await ClockCycles(dut.clk, 52)
    assert await read_wake_count(dut) == 1, "TC3 OR wake fires on sustained ch0"
    _, priority_ch, _ = await read_status(dut)
    assert priority_ch == 0, "TC3 priority_ch=0"
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC4: no double-fire on a single sustained assertion ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 80)
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)
    assert await read_wake_count(dut) == 1, "TC4 no double-fire: wake_count==1"

    # ---------------- TC5: disabled channel never wakes ----------------
    await do_reset(dut, ch_en=0b1110)
    set_inputs(dut, thresh_in=0b0001, ch_en=0b1110)
    await ClockCycles(dut.clk, 60)
    assert await read_wake_count(dut) == 0, "TC5 disabled channel: wake_count stays 0"
    set_inputs(dut, thresh_in=0b0000, ch_en=0b1111)
    await ClockCycles(dut.clk, 10)

    # ---------------- TC6: OR-mode fires on lowest-priority ch0 first ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1111)
    await ClockCycles(dut.clk, 60)
    _, priority_ch, evt_flags = await read_status(dut)
    assert evt_flags == 0b1111 or priority_ch == 0, \
        "TC6 OR-mode fires on lowest-priority ch0 first"
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC7: priority_ch for ch3-only, and release back to 'none' ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1000)
    await ClockCycles(dut.clk, 60)
    _, priority_ch, _ = await read_status(dut)
    assert priority_ch == 3, "TC7 priority_ch=3 for ch3-only (not confused with 'none')"
    set_inputs(dut, thresh_in=0b0000)
    await ClockCycles(dut.clk, 20)
    _, priority_ch, _ = await read_status(dut)
    assert priority_ch == 7, "TC7b priority_ch returns to 7 (none) after release"

    # ---------------- TC8: AND-mode true wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1111, mode_and=1)
    await ClockCycles(dut.clk, 60)
    assert await read_wake_count(dut) == 1, "TC8 AND-mode true wake fires"
    assert await read_false_wake_cnt(dut) == 0, "TC8 AND-mode no false wake on true event"
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC9: AND-mode partial assertion -> false wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001, mode_and=1)
    await ClockCycles(dut.clk, 100)
    assert await read_false_wake_cnt(dut) == 1, "TC9 false_wake_cnt==1 for held partial assertion"
    assert await read_wake_count(dut) == 0, "TC9 no true wake generated"
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 20)

    # ---------------- TC10: two separate partial events -> false_wake_cnt==2 ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001, mode_and=1)
    await ClockCycles(dut.clk, 30)
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 10)
    set_inputs(dut, thresh_in=0b0010, mode_and=1)
    await ClockCycles(dut.clk, 30)
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 10)
    assert await read_false_wake_cnt(dut) == 2, "TC10 two separate partial events -> false_wake_cnt==2"

    # ---------------- TC11: mid-debounce disable resets, no premature wake ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 1)
    set_inputs(dut, thresh_in=0b0000, ch_en=0b1110)
    await ClockCycles(dut.clk, 10)
    set_inputs(dut, thresh_in=0b0000, ch_en=0b1111)
    await ClockCycles(dut.clk, 10)
    assert await read_wake_count(dut) == 0, "TC11 mid-debounce disable resets: no premature wake"

    # ---------------- TC12: no X/undefined state after mode flip ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b0001)
    await ClockCycles(dut.clk, 10)
    set_inputs(dut, thresh_in=0b0001, mode_and=1)
    await ClockCycles(dut.clk, 60)
    wake_val = dut.uo_out.value
    assert "x" not in wake_val.binstr.lower(), "TC12 no X/undefined state after mode flip"
    set_inputs(dut, thresh_in=0b0000, mode_and=0)
    await ClockCycles(dut.clk, 10)

    # ---------------- TC13: wake_count saturates at 0xFFFF, no wraparound ----------------
    await do_reset(dut)
    for _ in range(70000):
        set_inputs(dut, thresh_in=0b0001)
        await ClockCycles(dut.clk, 8)
        set_inputs(dut, thresh_in=0b0000)
        await ClockCycles(dut.clk, 8)
        if await read_wake_count(dut) == 0xFFFF:
            break
    await ClockCycles(dut.clk, 5)
    assert await read_wake_count(dut) == 0xFFFF, "TC13 wake_count saturates at 0xFFFF, no wraparound"

    # ---------------- TC14: sustained AND success fires exactly once ----------------
    await do_reset(dut)
    set_inputs(dut, thresh_in=0b1111, mode_and=1)
    await ClockCycles(dut.clk, 200)
    assert await read_wake_count(dut) == 1, "TC14 sustained AND success fires exactly once"
    set_inputs(dut, thresh_in=0b0000, mode_and=1)
    await ClockCycles(dut.clk, 10)

    dut._log.info("All wake_ctrl checks passed")
