# SPDX-License-Identifier: Apache-2.0
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


def set_ui(dut, thresh_in, ch_en):
    dut.ui_in.value = (ch_en << 4) | thresh_in


def set_uio(dut, mode_and, reg_sel):
    dut.uio_in.value = (reg_sel << 1) | mode_and


async def reset(dut):
    dut.ena.value = 1
    dut.rst_n.value = 0
    set_ui(dut, 0, 0b1111)
    set_uio(dut, 0, 0)
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


def read_reg(dut, reg_sel):
    set_uio(dut, dut.uio_in.value & 1, reg_sel)
    return int(dut.uo_out.value)


@cocotb.test()
async def test_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    status = read_reg(dut, 0)
    wake_out = (status >> 7) & 1
    priority_ch = (status >> 4) & 0x7
    evt_flags = status & 0xF

    assert wake_out == 0
    assert priority_ch == 0x7
    assert evt_flags == 0

    wake_count = read_reg(dut, 1) | (read_reg(dut, 2) << 8)
    false_wake_cnt = read_reg(dut, 3) | (read_reg(dut, 4) << 8)
    assert wake_count == 0
    assert false_wake_cnt == 0


@cocotb.test()
async def test_or_mode_wake_on_ch0(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    set_ui(dut, 0b0001, 0b1111)
    set_uio(dut, 0, 0)
    await ClockCycles(dut.clk, 60)

    status = read_reg(dut, 0)
    priority_ch = (status >> 4) & 0x7
    evt_flags = status & 0xF

    wake_count = read_reg(dut, 1) | (read_reg(dut, 2) << 8)
    assert wake_count == 1, f"expected wake_count==1, got {wake_count}"
    assert evt_flags == 0b0001
    assert priority_ch == 0

    set_ui(dut, 0, 0b1111)
    await ClockCycles(dut.clk, 20)


@cocotb.test()
async def test_glitch_is_rejected(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    set_ui(dut, 0b0001, 0b1111)
    await ClockCycles(dut.clk, 2)
    set_ui(dut, 0, 0b1111)
    await ClockCycles(dut.clk, 10)

    wake_count = read_reg(dut, 1) | (read_reg(dut, 2) << 8)
    assert wake_count == 0


@cocotb.test()
async def test_and_mode_partial_assertion_false_wake(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    set_ui(dut, 0b0001, 0b1111)
    set_uio(dut, 1, 0)
    await ClockCycles(dut.clk, 100)

    wake_count = read_reg(dut, 1) | (read_reg(dut, 2) << 8)
    false_wake_cnt = read_reg(dut, 3) | (read_reg(dut, 4) << 8)

    assert wake_count == 0
    assert false_wake_cnt == 1

    set_ui(dut, 0, 0b1111)
    set_uio(dut, 0, 0)
    await ClockCycles(dut.clk, 10)


@cocotb.test()
async def test_and_mode_full_assertion_wakes_once(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())
    await reset(dut)

    set_ui(dut, 0b1111, 0b1111)
    set_uio(dut, 1, 0)
    await ClockCycles(dut.clk, 200)

    wake_count = read_reg(dut, 1) | (read_reg(dut, 2) << 8)
    false_wake_cnt = read_reg(dut, 3) | (read_reg(dut, 4) << 8)

    assert wake_count == 1
    assert false_wake_cnt == 0

    set_ui(dut, 0, 0b1111)
    set_uio(dut, 0, 0)
    await ClockCycles(dut.clk, 10)
