# =============================================================================
#  Bare-metal kernels for the coherent RISC-V SoC.
#
#  Produces, for every kernel in kernels/:
#     build/<name>.elf   linked image
#     build/<name>.hex   one 32-bit word per line, loaded into the ITCM
#     build/<name>.dis   disassembly, handy when a test misbehaves
#
#  Usage:  make            build everything
#          make TOOLCHAIN=/path/to/bin
# =============================================================================

TOOLCHAIN   ?= /d/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin
RISCV_PREFIX ?= riscv-none-elf-

CC      := $(TOOLCHAIN)/$(RISCV_PREFIX)gcc
OBJCOPY := $(TOOLCHAIN)/$(RISCV_PREFIX)objcopy
OBJDUMP := $(TOOLCHAIN)/$(RISCV_PREFIX)objdump

# CV32E40P with COREV_PULP=0 is RV32IMC; zicsr is needed for mhartid/mcycle.
ARCH    := rv32imc_zicsr
ABI     := ilp32

CFLAGS  := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medlow \
           -Os -g -std=c11 -ffreestanding -fno-builtin -fno-common \
           -Wall -Wextra -Ilib
LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
           -T lib/link.ld -Wl,--gc-sections -Wl,-Map,$(BUILD)/$*.map

BUILD   := build
SRCS    := $(wildcard kernels/*.c)
NAMES   := $(notdir $(basename $(SRCS)))
HEXES   := $(addprefix $(BUILD)/,$(addsuffix .hex,$(NAMES)))

.PHONY: all clean
all: $(HEXES)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.elf: kernels/%.c lib/crt0.S lib/link.ld | $(BUILD)
	$(CC) $(CFLAGS) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	      -T lib/link.ld -Wl,--gc-sections -Wl,-Map,$(BUILD)/$*.map \
	      -o $@ lib/crt0.S $<

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.rodata \
	           --only-section=.data $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	python ../scripts/bin2hex.py $< $@

$(BUILD)/%.dis: $(BUILD)/%.elf
	$(OBJDUMP) -d -S $< > $@

clean:
	rm -rf $(BUILD)
