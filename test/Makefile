# SPDX-FileCopyrightText: © 2026 Sreemathesh K
# SPDX-License-Identifier: Apache-2.0

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v

ifeq ($(SIM), icarus)
    COMPILE_ARGS += -DSIM
    COMPILE_ARGS += -DFUNCTIONAL
endif

VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

# TOPLEVEL is the name of the toplevel module in your Verilog file
TOPLEVEL = tt_um_sreemathesh_k_wake_ctrl

# MODULE is the basename of the Python test file
MODULE = test

include $(shell cocotb-config --makefiles)/Makefile.sim
