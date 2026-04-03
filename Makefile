# ================================
# Config
# ================================

tb ?= alu_tb

BUILD    := build
TB_DIR   := $(BUILD)/$(tb)
OBJDIR   := $(TB_DIR)/obj
WAVEDIR  := $(TB_DIR)/waves
LOGDIR   := $(TB_DIR)/logs

VERILATOR := verilator
VERILATOR_FLAGS := -Wall -Wno-fatal \
	--trace --trace-structs --trace-depth 99 \
	--timing \
	--sv -Irtl \
	-Wno-IMPORTSTAR -Wno-DECLFILENAME -Wno-GENUNNAMED \
	-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

# ================================
# Source Files
# ================================

# Core packages (order matters)
PKGS := \
	rtl/common/riscv_isa_pkg.sv \
	rtl/common/uarch_pkg.sv \
	rtl/common/branch_pkg.sv

# All RTL (safe but brute-force)
RTL_SRCS := $(shell find rtl -type f -name "*.sv" \
	! -name "*_pkg.sv" \
	! -name "*_tb.sv")

# Selected testbench
TB_SRC := $(shell find sim/tb -name "$(tb).sv")

# ================================
# Default Target
# ================================

all: run

# ================================
# Compile
# ================================

compile:
	@mkdir -p $(OBJDIR)
	@mkdir -p $(WAVEDIR)
	@mkdir -p $(LOGDIR)
	@$(VERILATOR) $(VERILATOR_FLAGS) \
	$(PKGS) \
	$(RTL_SRCS) \
	$(TB_SRC) \
	--cc \
	--exe $(CURDIR)/sim/sim_main.cpp \
	--build \
	-MAKEFLAGS -s \
	--top-module $(tb) \
	--Mdir $(OBJDIR) \
	-CFLAGS -DTOP_MODULE=V$(tb) \
	2>&1 | tee $(LOGDIR)/compile.log | grep -v '^Archive ar -rcs'

# ================================
# Run
# ================================

run: compile
	@echo "Running $(tb)..."
	@$(OBJDIR)/V$(tb) | tee $(LOGDIR)/run.log
	@mv -f *.vcd $(WAVEDIR)/ 2>/dev/null || true
	@echo "Output stored in $(TB_DIR)"

# ================================
# Open Waveform
# ================================

wave:
	@echo "Opening waveform..."
	@gtkwave $(WAVEDIR)/*.vcd

# ================================
# Clean
# ================================

clean:
	@echo "Cleaning build contents..."
	@rm -rf $(BUILD)/*

# ================================
# Regression (Run All TBs)
# ================================

regress:
	@for tb in $$(ls sim/tb/1-fetch/*.sv 2>/dev/null | xargs -n1 basename | sed 's/.sv//'); do \
		echo "==================================="; \
		echo "Running $$tb"; \
		$(MAKE) run tb=$$tb; \
	done
	