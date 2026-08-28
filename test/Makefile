SIM ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v

ifneq ($(GATES),yes)
COMPILE_ARGS += -I$(SRC_DIR)
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
else
COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DUSE_POWER_PINS
COMPILE_ARGS += -DSIM
COMPILE_ARGS += -DUNIT_DELAY=\#1
# This project is built for the IHP SG13G2 PDK (confirmed by the sg13g2_*
# cells in the synthesis log), NOT SkyWater sky130 -- the previous paths
# here (sky130A/libs.ref/sky130_fd_sc_hd/...) don't exist on the IHP
# runner, which is why gl_test failed to build the sim and never wrote
# test/results.xml.
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_io/verilog/sg13g2_io.v
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
endif

TOPLEVEL = tt_um_sreemathesh_k_wake_controller
MODULE = test

include $(shell cocotb-config --makefiles)/Makefile.sim
